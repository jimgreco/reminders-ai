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
any assistant conversation) with the date, time and the town you are in to
`POST /api/plan`. One Claude call
(`server/src/planner.js`) picks up to six to make progress on today, each with
why, a first step, and, where the assistant can help, the message that starts
it. The server stores none of it; the plan is kept on the device for the day.

The plan fits the day and the place. The planner is told the weekday and local
time, so a call to an office or a support line is not a weekend pick (the next
step becomes getting ready for it, with the day to call), and the town the
phone is in, so a task at the other house is left out unless part of it can be
done from here. It works out where a task belongs from its list, title and
notes. Messages to the assistant carry the same two facts, so the next steps it
suggests fit them too. The place is a name such as "East Hampton, NY", looked
up on the device (`RemindersAI/PlaceFinder.swift`); coordinates never leave it,
and with location off everything works as before, without the place.

Checking a pick off hides it for the rest of the day, repeating reminders
included. **Dismiss** leaves a reminder out for today, a week, a month, or for
good; dismissals are stored on the server by reminder id
(`/api/plan/dismissals`), so they apply on every device and the server drops
those reminders before Claude sees the list. **Not Suggesting** at the bottom of
the plan lists them, with Restore.

## Commitments from the weekly review

The weekly review site (`jimgreco/weekly-review`) proposes a few commitments
each Sunday. The ones you accept there become reminders here:

1. The site sends the accepted set for a week to `PUT /api/commitments?week=<monday>`
   with its own token, every time it changes. The server stores them and sends
   a silent push.
2. On its next sync the iPhone makes a reminder for each in a "Weekly
   Commitments" list (created on first use, not shared), due that Sunday, with
   how the commitment is judged in the notes. It reports each reminder's id.
3. Check one off, in this app or in Reminders, and the next sync reports it.
   The site reads that back (`GET /api/commitments?week=<monday>`) so the next
   review can use it as evidence for a commitment no app measures.
4. Un-accept a commitment and its open reminder is removed. When the review
   scores the week, the reminders still open are removed and the finished
   ones stay in Completed.

A reminder you delete yourself is not made again. The site's token
(`COMMITMENTS_TOKEN_SHA256`, bound to `COMMITMENTS_EMAIL`) works on
`/api/commitments` only; a signed-in user's token does not work there.

## What is stored where

| Where | What |
|---|---|
| Apple Reminders | every task: title, notes, dates, completion. Nothing is cached elsewhere. |
| Server database | each thread's messages, the edits waiting for the iPhone, push tokens, sign-in sessions, which reminder ids are dismissed from Plan My Day and until when, and the commitments accepted on the weekly review (their wording, their reminder's id and whether it is checked off). A reminder's details reach the server only when you message the assistant about it or plan your day (a plan is not stored). The name of the town you are in goes with both when location is allowed; it is passed to Claude and not stored. |
| Anthropic | each session's conversation, until the session is deleted. |
| iPhone Keychain | session tokens, this device only. |

## Layout

- `server/` Node 22 API: `src/app.js` routes, `src/agent.js` the agent
  definition and session loop, `src/planner.js` Plan My Day, `src/commitments.js` the weekly review's commitments, `src/store.js` memory and Postgres stores,
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
| `COMMITMENTS_TOKEN_SHA256`, `COMMITMENTS_EMAIL` | Hex SHA-256 of the weekly review site's token, and the account its commitments belong to. Either unset turns `/api/commitments` off (404). |
| `TRUST_PROXY_HOPS` | `1` behind nginx-proxy, for rate-limit IPs. |

## Release

Standard: `jimgreco/consolidated-deploy` `docs/APP_STANDARD.md`. First
activation is in `deploy/RUNBOOK.md`.
