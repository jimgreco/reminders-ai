# Turning on Task Sidekick (reminders-ai)

All steps are the owner's. Nothing here prints a secret; keep it that way.

## 1. Apple and Google

Done on 2026-11-18 (kept here as the record of what exists):

- App ID `com.jimgreco.remindersai` with **Sign in with Apple** and **Push
  Notifications**.
- Profile "Reminders AI App Store" (App Store distribution, existing
  distribution certificate); its UUID is in `release-policy.json`.
- App Store Connect record **Task Sidekick** (app id `6836446337`; "Reminders
  AI" was taken), internal TestFlight group "Family" with the owner in it. The
  home-screen name in `RemindersAI/Info.plist` matches the store name
  (ITMS-90129 rejects a taken one).
- APNs: the topic `com.jimgreco.remindersai` was added to the existing key
  `VQPG55B3R4` ("Week of Us Push Notifications", production only). Use that
  key's `.p8` for `APNS_PRIVATE_KEY`.

- Google Cloud (project CREAM): iOS OAuth client "Task Sidekick iOS" for the
  bundle ID. Client id
  `1018348991868-0ebtpdb7o8bt8vimj3ftbden3ivom3vu.apps.googleusercontent.com`
  (not a secret). For local device builds, put it and its reversed form in
  `project.yml`.
- Repository secrets already set: `IOS_API_BASE_URL`, `GOOGLE_IOS_CLIENT_ID`,
  `GOOGLE_IOS_REVERSED_CLIENT_ID`.

Still to do: the remaining repository secrets, which only you hold: the
TestFlight set from the app standard (`IOS_DIST_CERT_P12`,
`IOS_DIST_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY`) and the server
release set (`EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`, `EC2_SSH_KNOWN_HOSTS`).

## 2. Claude

The agent and its environment were created on 2026-11-18 with unrestricted
networking: `AGENT_ID=agent_01QX7fJYEJmAKUhUrLemaRyK`,
`AGENT_ENVIRONMENT_ID=env_01EMJciDTDcQ5iv3bgKWGwNz` (not secrets). To recreate:

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
GOOGLE_CLIENT_ID=1018348991868-0ebtpdb7o8bt8vimj3ftbden3ivom3vu.apps.googleusercontent.com
ALLOWED_EMAILS=<your Google and/or Apple ID email>
TRUST_PROXY_HOPS=1
ANTHROPIC_API_KEY=<your Claude API key>
AGENT_ID=agent_01QX7fJYEJmAKUhUrLemaRyK
AGENT_ENVIRONMENT_ID=env_01EMJciDTDcQ5iv3bgKWGwNz
APNS_KEY_ID=VQPG55B3R4
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
