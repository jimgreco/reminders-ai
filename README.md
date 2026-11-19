# Task Sidekick (reminders-ai)

Apple Reminders with an assistant in every item. The app looks and works like
Reminders, and Reminders stays the only store of tasks. Open an item and ask
the assistant to work on it: it researches on the web, asks you what it needs
to know, edits the reminder, adds follow-ups, and picks the conversation back
up whenever you return.

```
 iPhone app (SwiftUI)                         server (EC2, tasks.jim-greco.com)
 ┌───────────────────────────────┐   HTTPS   ┌──────────────────────────────────────┐
 │ EventKit: lists and reminders │ ────────► │ Sign in with Apple or Google, owner  │
 │ thread view, questions        │           │ threads, messages, queued edits      │──► Postgres
 │ applies the assistant's edits │ ◄──────── │ APNs push when a turn settles        │
 └───────────────────────────────┘   push    └──────────────────┬───────────────────┘
                                                                │ one session per reminder
                                                     Claude Managed Agents
                                                     (web search, web fetch, 4 custom tools)
```

## How a reminder gets worked

1. The app sends your message with the reminder as it is now (title, notes,
   due date, list). The server creates one agent session per reminder and
   reuses it for every follow-up.
2. The agent runs on Anthropic's side and keeps going after you close the app.
   The server polls the sessions that are working and stores what happens.
3. `ask_user` pauses the agent on a question. You get a push; your answer goes
   back as that tool's result and the agent carries on.
4. `update_reminder`, `create_reminder` and `complete_reminder` are queued as
   edits. The server cannot reach Reminders, so the iPhone applies them through
   EventKit on its next sync (on a push, on opening the app, or when a turn
   ends on screen) and acknowledges each one.
5. A session that has ended or reached its spending cap is replaced on the
   next message, with the conversation so far handed to the new one.

EventKit has no API for subtasks, so follow-up steps are separate reminders in
the same list.

## Plan My Day

The card at the top of the home screen sends your open reminders (title, list,
due date, priority, the first 1,000 characters of the notes, and the state of
any assistant conversation) to `POST /api/plan`. One Claude call
(`server/src/planner.js`) picks up to six to make progress on today, each with
why, a first step, and, where the assistant can help, the message that starts
it. The server stores none of it; the plan is kept on the device for the day.

## What is stored where

| Where | What |
|---|---|
| Apple Reminders | every task: title, notes, dates, completion. Nothing is cached elsewhere. |
| Server database | each thread's messages, the edits waiting for the iPhone, push tokens, sign-in sessions. A reminder's details reach the server only when you message the assistant about it or plan your day (a plan is not stored). |
| Anthropic | each session's conversation, until the session is deleted. |
| iPhone Keychain | session tokens, this device only. |

## Layout

- `server/` Node 22 API: `src/app.js` routes, `src/agent.js` the agent
  definition and session loop, `src/planner.js` Plan My Day, `src/store.js` memory and Postgres stores,
  `src/push.js` APNs, `scripts/setup-agent.js` one-time agent setup, `db/`
  migrations, `test/`.
- `RemindersAI/` iPhone app; `RemindersAITests/` unit tests. `project.yml` is
  the XcodeGen spec; `RemindersAI.xcodeproj` is generated from it and committed.
- `deploy/` database provisioning and the activation runbook.

## Run locally

```bash
cd server && npm ci
SESSION_SECRET=$(openssl rand -hex 32) REMINDERS_AI_DEV_SIGNIN=1 REMINDERS_AI_FAKE_AGENT=1 npm start
```

`REMINDERS_AI_FAKE_AGENT=1` plays a fixed exchange (a search, a question, two
reminder edits, a reply) without calling a model. For the real assistant set
`ANTHROPIC_API_KEY`, `AGENT_ID` and `AGENT_ENVIRONMENT_ID` instead (see
`deploy/RUNBOOK.md` step 2).

Open `RemindersAI.xcodeproj`, run on a simulator and use **Local dev sign in**
(debug builds only).

## Tests

```bash
cd server && npm test                                     # memory store
REMINDERS_AI_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/reminders_ai_test npm test   # + Postgres
xcodebuild -project RemindersAI.xcodeproj -scheme RemindersAI -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Server configuration

| Variable | Meaning |
|---|---|
| `DATABASE_URL` | `reminders_ai_runtime` connection. Required in production. |
| `SESSION_SECRET` | ≥ 32 chars, signs 15-minute access tokens. |
| `APPLE_BUNDLE_ID` | `com.jimgreco.remindersai`: the Apple identity-token audience and the push topic. |
| `GOOGLE_CLIENT_ID` | The iOS Google OAuth client id, the Google identity-token audience. Unset turns Google sign-in off. |
| `ALLOWED_EMAILS` / `ALLOWED_APPLE_SUBS` | Who may sign in. One is required in production. |
| `ANTHROPIC_API_KEY`, `AGENT_ID`, `AGENT_ENVIRONMENT_ID` | The Claude agent. The two ids are required in production. |
| `SESSION_BUDGET_CENTS` | Spending cap per agent session at list prices. Default 500; 0 for none. |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY` | Push notifications. All three or none. |
| `TRUST_PROXY_HOPS` | `1` behind nginx-proxy, for rate-limit IPs. |

## Release

Standard: `jimgreco/consolidated-deploy` `docs/APP_STANDARD.md`. First
activation is in `deploy/RUNBOOK.md`.
