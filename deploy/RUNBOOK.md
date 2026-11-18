# Turning on Reminders AI

All steps are the owner's. Nothing here prints a secret; keep it that way.

## 1. Apple

1. Developer portal: App ID `com.jimgreco.remindersai` with **Sign in with
   Apple** and **Push Notifications**.
2. App Store distribution provisioning profile for it, signed by the existing
   distribution certificate.
3. Keys: an **APNs** auth key (.p8). One key works for every app on the team;
   note its Key ID.
4. App Store Connect: a new app record for the bundle ID. "Reminders AI" is a
   working name: Apple rejects an upload whose home-screen or bundle name
   (`CFBundleDisplayName`, `CFBundleName` in `RemindersAI/Info.plist`) is taken
   (ITMS-90129), and may object to "Reminders" in a name. Pick the real name
   here and change both plist keys to match. Add yourself to an internal
   TestFlight group.
5. Fill `appId`, `profiles.app.uuid`, `profiles.app.name` and `groups[0].id` in
   `.github/scripts/release-policy.json` (they are `FILL_IN_…` until then, and
   the TestFlight job fails on them by design).
6. Repository secrets (environment `production`): the TestFlight set from the
   app standard, the server release set, and
   `IOS_API_BASE_URL=https://tasks.jim-greco.com`.

## 2. Claude

1. Console: an API key for this app, in its own workspace if you want its spend
   separate.
2. Create the agent and its environment once, from a checkout of `server/`:

   ```bash
   ANTHROPIC_API_KEY=… AGENT_NETWORKING=unrestricted npm run agent:setup
   ```

   `unrestricted` lets web search and web fetch reach any public site, which
   open-ended research needs. The agent has no shell or file tools and its
   sandbox holds no secrets. `limited` with `AGENT_ALLOWED_HOSTS=a.com,b.com`
   confines it to those sites instead. The script prints `AGENT_ID` and
   `AGENT_ENVIRONMENT_ID`.
3. After a change to the prompt or tools in `server/src/agent.js`, run the
   script again with `AGENT_ID` and `AGENT_ENVIRONMENT_ID` set: it updates the
   same agent. Threads already in progress keep the version they started on.

Anthropic runs the agent loop and keeps each session's history until the
session is deleted. Managed Agents is in beta and bills session running time
on top of tokens. `SESSION_BUDGET_CENTS` (default 500) caps each session at
list prices; a thread that reaches it continues in a new session on the next
message.

## 3. Database (shared_db on the host)

```bash
umask 077
MIGRATOR_PW=$(openssl rand -hex 24); RUNTIME_PW=$(openssl rand -hex 24)
docker exec -i shared_db psql -U admin -v ON_ERROR_STOP=1 \
  -v migrator_pw="$MIGRATOR_PW" -v runtime_pw="$RUNTIME_PW" < provision.sql
```

Migrations (now and for every later `db/NNN_*.sql`), with the migrator allowed
to log in only while they run:

```bash
docker exec shared_db psql -U admin -c "ALTER ROLE reminders_ai_migrator LOGIN"
docker run --rm --network deploy_default -e MIGRATION_ROLE=reminders_ai_owner \
  -e MIGRATION_DATABASE_URL="postgresql://reminders_ai_migrator:$MIGRATOR_PW@shared_db:5432/reminders_ai" \
  ghcr.io/jimgreco/reminders-ai:<sha> node src/migrate.js
docker exec shared_db psql -U admin -c "ALTER ROLE reminders_ai_migrator NOLOGIN"
```

Store `MIGRATOR_PW` in your password manager, not on the host.

## 4. Runtime environment (`~/deploy/reminders-ai.env`, mode 600)

```bash
cat > ~/deploy/reminders-ai.env <<EOT
NODE_ENV=production
DATABASE_URL=postgresql://reminders_ai_runtime:$RUNTIME_PW@shared_db:5432/reminders_ai
SESSION_SECRET=$(openssl rand -hex 32)
APPLE_BUNDLE_ID=com.jimgreco.remindersai
ALLOWED_EMAILS=<your Apple ID email>
TRUST_PROXY_HOPS=1
ANTHROPIC_API_KEY=<from step 2.1>
AGENT_ID=<from step 2.2>
AGENT_ENVIRONMENT_ID=<from step 2.2>
APNS_KEY_ID=<from step 1.3>
APNS_TEAM_ID=V6JPQCD336
APNS_PRIVATE_KEY=<the .p8 contents on one line, newlines written as \n>
EOT
chmod 600 ~/deploy/reminders-ai.env
```

If Sign in with Apple hides your email, the app says "this app is private" and
the server logs `sign-in refused for Apple sub <id>`; put that id in
`ALLOWED_APPLE_SUBS` and recreate the service.

## 5. Service, proxy, first start

1. Merge the consolidated-deploy PR that adds the `reminders-ai` service
   (profile `reminders-ai`, overlay `~/deploy/reminders-ai.compose.yml`).
2. nginx-proxy: `tasks.jim-greco.com` → `reminders-ai:8792`, with a
   certificate. DNS: an A record for `tasks.jim-greco.com` to the host.
3. Start once by hand (the release engine only replaces running services):
   `REMINDERS_AI_IMAGE=ghcr.io/jimgreco/reminders-ai:<sha> docker-compose -f docker-compose.yml -f reminders-ai.compose.yml --profile reminders-ai up -d --no-deps reminders-ai`
4. `curl -s https://tasks.jim-greco.com/health` → `{"ok":true,…,"db":true,…}`.

## 6. Backups

Backups follow the shared standard (consolidated-deploy `scripts/backup-pilot`).
After the first nightly run, run the restore test once by hand and confirm the
freshness workflow passes.
