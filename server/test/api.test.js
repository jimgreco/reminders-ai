import { test, describe, before, after } from "node:test";
import { FakePlanClient, Planner } from "../src/planner.js";
import assert from "node:assert/strict";
import http from "node:http";
import pg from "pg";
import { createApp, loadConfig, validateReminder } from "../src/app.js";
import { Assistant, agentDefinition, validateReminderEdit } from "../src/agent.js";
import { Pusher, buildPayload, loadPushConfig } from "../src/push.js";
import { MemoryStore, PostgresStore } from "../src/store.js";
import { migrate } from "../src/migrate.js";

const OWNER = "owner@example.com";
const quiet = { warn() {}, error() {}, log() {} };

function baseEnv(extra = {}) {
  return {
    SESSION_SECRET: "x".repeat(40),
    APPLE_BUNDLE_ID: "com.jimgreco.remindersai",
    GOOGLE_CLIENT_ID: "test.apps.googleusercontent.com",
    ALLOWED_EMAILS: OWNER,
    AGENT_ID: "agent_test",
    AGENT_ENVIRONMENT_ID: "env_test",
    ...extra
  };
}

// Fake Apple verifier: the "identity token" is a JSON string of the claims.
async function fakeApple(token) {
  const claims = JSON.parse(token);
  if (claims.invalid) throw new Error("bad signature");
  return claims;
}

// Stands in for the Anthropic SDK's Managed Agents surface.
class FakeAgents {
  constructor() {
    this.sessions = new Map();
    this.created = [];
    this.clock = Date.parse("2026-11-18T12:00:00Z");
    const self = this;
    this.beta = {
      sessions: {
        async create(params) {
          const id = `sesn_${self.sessions.size + 1}`;
          self.sessions.set(id, { status: "idle", events: [], sent: [], refuse: false });
          self.created.push({ id, params });
          return { id };
        },
        async retrieve(id) {
          return { id, status: self.sessions.get(id).status };
        },
        events: {
          async send(id, { events }) {
            const session = self.sessions.get(id);
            if (session.refuse) throw Object.assign(new Error("session cannot accept events"), { status: 400 });
            session.sent.push(...events);
            return {};
          },
          list(id) {
            const events = [...self.sessions.get(id).events];
            return { async *[Symbol.asyncIterator]() { yield* events; } };
          }
        }
      }
    };
  }

  emit(sessionId, ...events) {
    const session = this.sessions.get(sessionId);
    for (const event of events) {
      this.clock += 1000;
      session.events.push({ id: `sevt_${session.events.length + 1}_${sessionId}`, processed_at: new Date(this.clock).toISOString(), ...event });
    }
    return session.events.slice(-events.length);
  }

  sent(sessionId) {
    return this.sessions.get(sessionId).sent;
  }
}

const says = (text) => ({ type: "agent.message", content: [{ type: "text", text }] });
const idle = (type = "end_turn") => ({ type: "session.status_idle", stop_reason: { type } });
const tool = (name, input) => ({ type: "agent.custom_tool_use", name, input });

async function start(store, env = baseEnv()) {
  const config = loadConfig(env);
  const agents = new FakeAgents();
  const pushes = [];
  const push = { notify: async (userId, message) => { pushes.push(message); } };
  const assistant = new Assistant({ store, client: agents, config, push, log: quiet });
  const planClient = new FakePlanClient();
  const planner = new Planner({ client: planClient });
  const server = http.createServer(createApp({ store, config, assistant, planner, verifyAppleToken: fakeApple, verifyGoogleToken: fakeApple }));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, path, { body, token } = {}) => {
    const response = await fetch(base + path, {
      method,
      headers: {
        ...(body ? { "content-type": "application/json" } : {}),
        ...(token ? { authorization: `Bearer ${token}` } : {})
      },
      body: body ? JSON.stringify(body) : undefined
    });
    const text = await response.text();
    return { status: response.status, body: text ? JSON.parse(text) : null };
  };
  const signIn = async (email = OWNER) => {
    const r = await call("POST", "/auth/apple", { body: { identityToken: JSON.stringify({ sub: `sub-${email}`, email, email_verified: true }) } });
    return r.body;
  };
  const raw = (path, token) => fetch(base + path, { headers: token ? { authorization: `Bearer ${token}` } : {} });
  return { call, raw, signIn, agents, assistant, pushes, config, planClient, close: () => new Promise((r) => server.close(r)) };
}

const REMINDER = { title: "Renew passport", notes: "expires in March", list: "Personal", due: "2026-12-01", priority: "high", timeZone: "America/New_York" };
const RID = "ABC-123/x";
const threadPath = (suffix = "") => `/api/threads/${encodeURIComponent(RID)}${suffix}`;

function suite(name, makeStore) {
  describe(name, () => {
    let app;
    let store;
    let token;
    before(async () => {
      store = await makeStore();
      app = await start(store);
      token = (await app.signIn()).accessToken;
    });
    after(async () => {
      await app.close();
      await store.close?.();
    });

    const ask = (text) => app.call("POST", threadPath("/messages"), { token, body: { text, reminder: REMINDER } });
    const poll = () => app.assistant.pollOnce();
    const thread = async () => (await app.call("GET", threadPath(), { token })).body;

    test("health reports the database and build", async () => {
      const r = await app.call("GET", "/health");
      assert.equal(r.status, 200);
      assert.deepEqual(r.body, { ok: true, status: "ok", db: true, build: "dev" });
    });

    test("Google sign-in reaches the same account as Apple via the verified email", async () => {
      const apple = await app.signIn();
      const google = await app.call("POST", "/auth/google", {
        body: { idToken: JSON.stringify({ sub: "google-owner", email: OWNER.toUpperCase(), email_verified: true }) }
      });
      assert.equal(google.status, 200);
      assert.equal(google.body.user.id, apple.user.id);
      assert.equal((await app.call("GET", "/api/sync", { token: google.body.accessToken })).status, 200);
      const stranger = await app.call("POST", "/auth/google", {
        body: { idToken: JSON.stringify({ sub: "google-x", email: "someone@else.com", email_verified: true }) }
      });
      assert.equal(stranger.status, 403);
      const unverified = await app.call("POST", "/auth/google", {
        body: { idToken: JSON.stringify({ sub: "google-y", email: OWNER, email_verified: false }) }
      });
      assert.equal(unverified.status, 403, "an unverified email is neither allowed nor linked");
      const forged = await app.call("POST", "/auth/google", { body: { idToken: JSON.stringify({ invalid: true }) } });
      assert.equal(forged.status, 401);
    });

    test("only the owner can sign in, and the API needs a session", async () => {
      const refused = await app.call("POST", "/auth/apple", {
        body: { identityToken: JSON.stringify({ sub: "stranger", email: "x@example.com", email_verified: true }) }
      });
      assert.equal(refused.status, 403);
      const unverified = await app.call("POST", "/auth/apple", {
        body: { identityToken: JSON.stringify({ sub: "s2", email: OWNER, email_verified: false }) }
      });
      assert.equal(unverified.status, 403);
      assert.equal((await app.call("GET", "/api/sync")).status, 401);
      assert.equal((await app.call("POST", "/auth/dev", { body: {} })).status, 404);
      assert.equal((await app.call("GET", threadPath(), { token })).status, 404);
    });

    test("the first message starts a session with the reminder's details", async () => {
      const r = await ask("Work on this");
      assert.equal(r.status, 200);
      assert.equal(r.body.status, "working");
      assert.equal(r.body.reminderId, RID);
      assert.deepEqual(r.body.messages.map((m) => [m.role, m.text]), [["user", "Work on this"]]);
      assert.equal(app.agents.created.length, 1);
      const { params } = app.agents.created[0];
      assert.equal(params.agent, "agent_test");
      assert.equal(params.environment_id, "env_test");
      assert.deepEqual(params.budget, { type: "limit", max_list_cost: { amount: "500", currency: "USD" } });
      const [sent] = app.agents.sent("sesn_1");
      assert.equal(sent.type, "user.message");
      const text = sent.content[0].text;
      assert.match(text, /Title: Renew passport/);
      assert.match(text, /Due: 2026-12-01/);
      assert.match(text, /expires in March/);
      assert.match(text, /time zone America\/New_York/);
      assert.ok(text.endsWith("Work on this"));
    });

    test("research activity and a question reach the thread, with a push", async () => {
      app.agents.emit("sesn_1",
        { type: "session.status_running" },
        { type: "agent.tool_use", name: "web_search", input: { query: "passport renewal form DS-82" }, evaluated_permission: "allow" },
        { type: "agent.tool_use", name: "web_fetch", input: { url: "https://www.travel.state.gov/renew" }, evaluated_permission: "allow" },
        says("You can renew by mail."),
        tool("ask_user", { question: "Routine or expedited?", options: ["Routine", "Expedited", ""] }),
        idle("requires_action"));
      await poll();
      const t = await thread();
      assert.equal(t.status, "needs_input");
      assert.equal(t.unread, true);
      assert.deepEqual(t.messages.slice(1).map((m) => [m.role, m.text]), [
        ["activity", "Searched: passport renewal form DS-82"],
        ["activity", "Read travel.state.gov"],
        ["assistant", "You can renew by mail."],
        ["question", "Routine or expedited?"]
      ]);
      assert.deepEqual(t.messages.at(-1).options, ["Routine", "Expedited"]);
      assert.deepEqual(app.pushes.at(-1), { title: "Renew passport", body: "Question: Routine or expedited?", reminderId: RID });
      // Polling again changes nothing: every event is applied once.
      await app.assistant.sync((await app.assistant.store.listThreads((await app.call("GET", "/api/me", { token })).body.id))[0].id);
      assert.equal((await thread()).messages.length, 5);
    });

    test("the answer goes back as the question's result", async () => {
      const questionEvent = app.agents.sessions.get("sesn_1").events.find((e) => e.name === "ask_user");
      const r = await ask("Expedited");
      assert.equal(r.body.status, "working");
      assert.equal(r.body.unread, false);
      assert.deepEqual(app.agents.sent("sesn_1").at(-1), {
        type: "user.custom_tool_result", custom_tool_use_id: questionEvent.id, content: [{ type: "text", text: "Expedited" }]
      });
      assert.equal(app.agents.created.length, 1);
    });

    test("reminder edits are queued for the iPhone and acknowledged once", async () => {
      const [, update, create, bad] = app.agents.emit("sesn_1",
        { type: "session.status_running" },
        tool("update_reminder", { notes: "Form DS-82, expedited, $190", due: "2026-11-25" }),
        tool("create_reminder", { title: "Get passport photo taken", priority: "medium" }),
        tool("update_reminder", { due: "next week" }),
        idle("requires_action"));
      await poll();
      const results = app.agents.sent("sesn_1").filter((e) => e.type === "user.custom_tool_result").slice(-3);
      assert.deepEqual(results.map((e) => [e.custom_tool_use_id, e.is_error]), [[update.id, false], [create.id, false], [bad.id, true]]);
      assert.equal((await thread()).status, "working");
      assert.deepEqual(app.pushes.at(-1), { title: "Renew passport", body: null, reminderId: RID });

      const sync = await app.call("GET", "/api/sync", { token });
      assert.deepEqual(sync.body.threads.map((t) => [t.reminderId, t.status]), [[RID, "working"]]);
      assert.deepEqual(sync.body.ops.map((o) => [o.reminderId, o.kind, o.payload]), [
        [RID, "update", { notes: "Form DS-82, expedited, $190", due: "2026-11-25" }],
        [RID, "create", { title: "Get passport photo taken", priority: "medium" }]
      ]);
      const [first, second] = sync.body.ops;
      assert.equal((await app.call("POST", `/api/ops/${first.id}/ack`, { token, body: {} })).status, 200);
      assert.equal((await app.call("POST", `/api/ops/${second.id}/ack`, { token, body: { error: "list is read-only" } })).status, 200);
      assert.equal((await app.call("POST", `/api/ops/${first.id}/ack`, { token, body: {} })).status, 200);
      assert.equal((await app.call("POST", "/api/ops/00000000-0000-4000-8000-000000000000/ack", { token, body: {} })).status, 404);
      assert.deepEqual((await app.call("GET", "/api/sync", { token })).body.ops, []);
    });

    test("finishing a turn settles the thread and notifies", async () => {
      app.agents.emit("sesn_1", { type: "session.status_running" }, says("All set: mail the form by Friday."), idle());
      await poll();
      const t = await thread();
      assert.equal(t.status, "idle");
      assert.equal(t.unread, true);
      assert.equal(app.pushes.at(-1).body, "All set: mail the form by Friday.");
      const read = await app.call("POST", threadPath("/read"), { token });
      assert.equal(read.body.unread, false);
    });

    test("a follow-up continues the same session; a stale idle does not hide running work", async () => {
      const r = await ask("What about the photo?");
      assert.equal(r.body.status, "working");
      assert.equal(app.agents.created.length, 1);
      assert.equal(app.agents.sent("sesn_1").at(-1).type, "user.message");
      app.agents.emit("sesn_1", idle());
      app.agents.sessions.get("sesn_1").status = "running";
      await poll();
      assert.equal((await thread()).status, "working");
      await app.call("POST", threadPath("/stop"), { token });
      assert.deepEqual(app.agents.sent("sesn_1").at(-1), { type: "user.interrupt" });
    });

    test("when the session ends, the next message carries the conversation into a new one", async () => {
      app.agents.emit("sesn_1", { type: "session.status_terminated" });
      await poll();
      let t = await thread();
      assert.equal(t.status, "error");
      assert.equal(t.messages.at(-1).role, "error");
      const r = await ask("Still there?");
      assert.equal(r.body.status, "working");
      assert.equal(app.agents.created.length, 2);
      const text = app.agents.sent("sesn_2")[0].content[0].text;
      assert.match(text, /Earlier conversation about this reminder/);
      assert.match(text, /Person: Expedited/);
      assert.match(text, /You: All set: mail the form by Friday\./);
      assert.ok(text.endsWith("Still there?"));

      // A session that refuses messages (for example at its spending cap) is replaced too.
      app.agents.emit("sesn_2", { type: "session.status_running" }, idle("budget_reached"));
      await poll();
      t = await thread();
      assert.equal(t.status, "error");
      assert.match(t.messages.at(-1).text, /spending limit/);
      await ask("Keep going");
      assert.equal(app.agents.created.length, 3);
    });

    test("a conversation follows its reminder to a new id", async () => {
      const moved = "MOVED-456";
      const movedPath = (suffix = "") => `/api/threads/${encodeURIComponent(moved)}${suffix}`;
      const before = await thread();
      let r = await app.call("POST", threadPath("/move"), { token, body: { to: moved } });
      assert.equal(r.status, 200);
      assert.equal(r.body.reminderId, moved);
      assert.equal((await app.call("GET", threadPath(), { token })).status, 404);
      const after = (await app.call("GET", movedPath(), { token })).body;
      assert.deepEqual(after.messages.map((m) => m.id), before.messages.map((m) => m.id));
      // Moving onto a reminder that already has a conversation is refused.
      await app.call("POST", threadPath("/messages"), { token, body: { text: "hi", reminder: REMINDER } });
      r = await app.call("POST", threadPath("/move"), { token, body: { to: moved } });
      assert.equal(r.status, 409);
      r = await app.call("POST", movedPath("/move"), { token, body: {} });
      assert.equal(r.status, 400);
      // Put things back for the tests that follow.
      await app.call("DELETE", threadPath(), { token });
      r = await app.call("POST", movedPath("/move"), { token, body: { to: RID } });
      assert.equal(r.status, 200);
    });

    test("plan my day picks from the reminders sent and stores nothing", async () => {
      const reminders = [
        { id: "R-1", title: "Renew passport", list: "Personal", due: "2026-12-01", priority: "high", notes: "x".repeat(5000), conversation: "idle" },
        { id: "R-2", title: "Book dentist", list: "Health" },
        { id: "R-2", title: "Duplicate id is dropped" },
        { id: "R-3", title: "   " }
      ];
      const r = await app.call("POST", "/api/plan", { token, body: { reminders, timeZone: "America/New_York", now: "2026-11-18T09:00:00-05:00" } });
      assert.equal(r.status, 200);
      assert.deepEqual(r.body.suggestions.map((s) => s.reminderId), ["R-1", "R-2"]);
      assert.equal(r.body.suggestions[0].assistantPrompt, "Work out the first step for me.");
      const sent = app.planClient.requests.at(-1);
      assert.equal(sent.output_config.format.type, "json_schema");
      const prompt = sent.messages[0].content;
      assert.match(prompt, /time zone America\/New_York/);
      assert.match(prompt, /"conversation":"idle"/);
      assert.ok(!prompt.includes("x".repeat(1001)), "notes are cut short");
      assert.ok(!prompt.includes("Duplicate"));

      assert.equal((await app.call("POST", "/api/plan", { body: { reminders } })).status, 401);
      assert.equal((await app.call("POST", "/api/plan", { token, body: { reminders: "all" } })).status, 400);
      const empty = await app.call("POST", "/api/plan", { token, body: { reminders: [] } });
      assert.deepEqual(empty.body.suggestions, []);
    });

    test("dismissed reminders are left out of the plan until their time is up", async () => {
      const path = (id) => `/api/plan/dismissals/${encodeURIComponent(id)}`;
      const soon = new Date(Date.now() + 60 * 60_000).toISOString();
      let r = await app.call("PUT", path("D-1/x"), { token, body: { until: soon } });
      assert.equal(r.status, 200);
      assert.equal(r.body.reminderId, "D-1/x");
      r = await app.call("PUT", path("D-2"), { token, body: { until: null } });
      assert.equal(r.status, 200);
      assert.equal(r.body.until, null);
      assert.equal((await app.call("PUT", path("D-3"), { token, body: { until: "2000-01-01T00:00:00Z" } })).status, 400);
      assert.equal((await app.call("PUT", path("D-3"), { token, body: { until: "soon" } })).status, 400);
      assert.equal((await app.call("GET", "/api/plan/dismissals", {})).status, 401);

      r = await app.call("GET", "/api/plan/dismissals", { token });
      assert.deepEqual(r.body.dismissals.map((d) => d.reminderId).sort(), ["D-1/x", "D-2"]);
      assert.equal(new Date(r.body.dismissals.find((d) => d.reminderId === "D-1/x").until).toISOString(), soon);

      const reminders = [{ id: "D-1/x", title: "Dismissed for an hour" }, { id: "D-2", title: "Dismissed for good" }, { id: "D-4", title: "Still in" }];
      r = await app.call("POST", "/api/plan", { token, body: { reminders } });
      assert.deepEqual(r.body.suggestions.map((s) => s.reminderId), ["D-4"]);
      assert.ok(!app.planClient.requests.at(-1).messages[0].content.includes("Dismissed"));

      assert.equal((await app.call("DELETE", path("D-2"), { token })).status, 200);
      r = await app.call("GET", "/api/plan/dismissals", { token });
      assert.deepEqual(r.body.dismissals.map((d) => d.reminderId), ["D-1/x"]);
      await app.call("DELETE", path("D-1/x"), { token });
    });

    test("a plan that names unknown reminders keeps only real ones", async () => {
      const planner = new Planner({ client: { messages: { create: async () => ({
        stop_reason: "end_turn",
        content: [{ type: "text", text: JSON.stringify({ summary: "s", suggestions: [
          { reminderId: "nope", reason: "", nextStep: "", assistantPrompt: "" },
          { reminderId: "R-1", reason: "why", nextStep: "do", assistantPrompt: "" },
          { reminderId: "R-1", reason: "again", nextStep: "do", assistantPrompt: "" }
        ] }) }]
      }) } } });
      const plan = await planner.plan({ reminders: [{ id: "R-1", title: "t" }], timeZone: "", now: "" });
      assert.deepEqual(plan.suggestions.map((s) => s.reason), ["why"]);
      const refused = new Planner({ client: { messages: { create: async () => ({ stop_reason: "refusal", content: [] }) } } });
      await assert.rejects(refused.plan({ reminders: [{ id: "R-1", title: "t" }] }), (e) => e.status === 502);
    });

    test("photos reach the agent as images, are listed without their data, and are served only to the owner", async () => {
      const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64, 7)]);
      const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), Buffer.alloc(32, 1)]);
      const path = "/api/threads/photo-reminder/messages";
      const sent = await app.call("POST", path, {
        token,
        body: {
          text: "What size filter is this?", reminder: { ...REMINDER, title: "Replace furnace filter" },
          images: [{ mediaType: "image/jpeg", data: jpeg.toString("base64") }, { mediaType: "image/png", data: png.toString("base64") }]
        }
      });
      assert.equal(sent.status, 200);
      const mine = sent.body.messages.find((m) => m.role === "user");
      assert.equal(mine.attachments.length, 2);
      assert.deepEqual(Object.keys(mine.attachments[0]).sort(), ["id", "mediaType"], "no image data in the thread");

      const session = [...app.agents.sessions.values()].at(-1);
      const content = session.sent.at(-1).content;
      assert.equal(content[0].type, "text");
      assert.match(content[0].text, /What size filter is this\?/);
      assert.deepEqual(content.slice(1).map((c) => [c.type, c.source.type, c.source.media_type]),
        [["image", "base64", "image/jpeg"], ["image", "base64", "image/png"]]);
      assert.equal(content[1].source.data, jpeg.toString("base64"));

      const fetched = await app.raw(`/api/attachments/${mine.attachments[0].id}`, token);
      assert.equal(fetched.status, 200);
      assert.equal(fetched.headers.get("content-type"), "image/jpeg");
      assert.deepEqual(Buffer.from(await fetched.arrayBuffer()), jpeg);
      assert.equal((await app.raw(`/api/attachments/${mine.attachments[0].id}`)).status, 401);
      const stranger = await store.upsertUserByIdentity({ provider: "dev", subject: "x", email: "x@example.com", emailVerified: true });
      assert.equal(await store.getAttachment(stranger.id, mine.attachments[0].id), null, "another user's photo is not found");
      assert.equal((await app.raw("/api/attachments/00000000-0000-0000-0000-000000000000", token)).status, 404);

      const photoOnly = await app.call("POST", path, {
        token, body: { text: "", reminder: REMINDER, images: [{ mediaType: "image/png", data: png.toString("base64") }] }
      });
      assert.equal(photoOnly.status, 200);
      assert.match(JSON.stringify(session.sent.at(-1).content[0]), /sent a photo/);

      const bad = (images) => app.call("POST", path, { token, body: { text: "x", reminder: REMINDER, images } });
      assert.equal((await bad([{ mediaType: "image/jpeg", data: png.toString("base64") }])).status, 400, "bytes must match the type");
      assert.equal((await bad([{ mediaType: "image/svg+xml", data: png.toString("base64") }])).status, 400);
      assert.equal((await bad(Array(5).fill({ mediaType: "image/png", data: png.toString("base64") }))).status, 400);
      await app.call("DELETE", "/api/threads/photo-reminder", { token });
    });

    test("bad input is rejected; deleting a thread removes it", async () => {
      const post = (body) => app.call("POST", threadPath("/messages"), { token, body });
      assert.equal((await post({ text: "", reminder: REMINDER })).status, 400);
      assert.equal((await post({ text: "hi", reminder: { title: " " } })).status, 400);
      assert.equal((await post({ text: "hi" })).status, 400);
      assert.equal((await app.call("POST", "/api/devices", { token, body: { token: "nope" } })).status, 400);
      assert.equal((await app.call("POST", "/api/devices", { token, body: { token: "ab".repeat(32), sandbox: true } })).status, 200);
      assert.equal((await app.call("DELETE", threadPath(), { token })).status, 200);
      assert.equal((await app.call("GET", threadPath(), { token })).status, 404);
      assert.deepEqual((await app.call("GET", "/api/sync", { token })).body, { threads: [], ops: [] });
    });

    test("refresh tokens rotate", async () => {
      const session = await app.signIn();
      const next = await app.call("POST", "/auth/refresh", { body: { refreshToken: session.refreshToken } });
      assert.equal(next.status, 200);
      assert.equal((await app.call("POST", "/auth/refresh", { body: { refreshToken: session.refreshToken } })).status, 401);
    });
  });
}

suite("memory store", async () => new MemoryStore());

const databaseURL = process.env.REMINDERS_AI_TEST_DATABASE_URL;
if (databaseURL) {
  suite("postgres store", async () => {
    const admin = new pg.Client({ connectionString: databaseURL });
    await admin.connect();
    await admin.query("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
    await admin.end();
    await migrate(databaseURL);
    return new PostgresStore(databaseURL);
  });
}

describe("configuration", () => {
  test("production requires a database, an allow-list and the agent ids", () => {
    const prod = { ...baseEnv(), NODE_ENV: "production", DATABASE_URL: "postgresql://x" };
    assert.doesNotThrow(() => loadConfig(prod));
    assert.throws(() => loadConfig({ ...prod, DATABASE_URL: "" }), /DATABASE_URL/);
    assert.throws(() => loadConfig({ ...prod, ALLOWED_EMAILS: "" }), /ALLOWED_EMAILS/);
    assert.throws(() => loadConfig({ ...prod, AGENT_ID: "" }), /AGENT_ID/);
    assert.throws(() => loadConfig({ ...prod, REMINDERS_AI_DEV_SIGNIN: "1" }), /DEV_SIGNIN/);
    assert.throws(() => loadConfig({ ...baseEnv(), SESSION_SECRET: "short" }), /SESSION_SECRET/);
    assert.throws(() => loadConfig({ ...baseEnv(), SESSION_BUDGET_CENTS: "1.5" }), /SESSION_BUDGET_CENTS/);
    assert.equal(loadConfig({ ...baseEnv(), SESSION_BUDGET_CENTS: "0" }).sessionBudgetCents, 0);
  });

  test("Google sign-in is off until a client id is set", async () => {
    const app = await start(new MemoryStore(), baseEnv({ GOOGLE_CLIENT_ID: "" }));
    const r = await app.call("POST", "/auth/google", { body: { idToken: "{}" } });
    assert.equal(r.status, 503);
    await app.close();
  });

  test("without agent ids the assistant is off and says so", async () => {
    const app = await start(new MemoryStore(), baseEnv({ AGENT_ID: "" }));
    const { accessToken } = await app.signIn();
    const me = await app.call("GET", "/api/me", { token: accessToken });
    assert.equal(me.body.assistant, false);
    const r = await app.call("POST", threadPath("/messages"), { token: accessToken, body: { text: "hi", reminder: REMINDER } });
    assert.equal(r.status, 503);
    await app.close();
  });
});

describe("agent definition and edits", () => {
  test("only the web tools and the four custom tools are enabled", () => {
    const def = agentDefinition("claude-opus-5-5");
    assert.equal(def.model, "claude-opus-5-5");
    const [toolset, ...custom] = def.tools;
    assert.equal(toolset.default_config.enabled, false);
    assert.deepEqual(toolset.configs.map((c) => [c.name, c.enabled]), [["web_search", true], ["web_fetch", true]]);
    assert.deepEqual(custom.map((t) => t.name), ["ask_user", "update_reminder", "create_reminder", "complete_reminder"]);
  });

  test("reminder edits are validated", () => {
    assert.deepEqual(validateReminderEdit("update", { title: "A", due: "none", priority: "low" }),
      { payload: { title: "A", due: null, priority: "low" } });
    assert.deepEqual(validateReminderEdit("create", { title: "B", due: "2026-12-01T09:30" }),
      { payload: { title: "B", due: "2026-12-01T09:30" } });
    assert.deepEqual(validateReminderEdit("complete", { anything: 1 }), { payload: {} });
    assert.match(validateReminderEdit("update", {}).error, /nothing to change/);
    assert.match(validateReminderEdit("create", { notes: "x" }).error, /title is required/);
    assert.match(validateReminderEdit("create", { title: "x", due: "none" }).error, /due/);
    assert.match(validateReminderEdit("update", { due: "2026-02-30" }).error, /due/);
    assert.match(validateReminderEdit("update", { due: "2026-02-03T25:00" }).error, /due/);
    assert.match(validateReminderEdit("update", { priority: "urgent" }).error, /priority/);
    assert.match(validateReminderEdit("update", { title: "  " }).error, /title/);
  });

  test("the reminder snapshot is normalized", () => {
    assert.deepEqual(validateReminder({ title: " T ", priority: "weird", completed: true }),
      { title: "T", notes: "", list: "", due: "", timeZone: "", now: "", priority: "none", completed: true });
  });
});

describe("push", () => {
  test("configuration is all or nothing", () => {
    assert.equal(loadPushConfig({}), null);
    assert.throws(() => loadPushConfig({ APNS_KEY_ID: "K" }), /must be set together/);
    const config = loadPushConfig({ APNS_PRIVATE_KEY: "a\\nb", APNS_KEY_ID: "K", APNS_TEAM_ID: "T", APPLE_BUNDLE_ID: "com.x" });
    assert.equal(config.key, "a\nb");
  });

  test("alerts and silent pushes are built and dead tokens are dropped", async () => {
    assert.deepEqual(buildPayload({ title: "T", body: null, reminderId: "r" }), { aps: { "content-available": 1 }, reminderId: "r" });
    const { privateKey } = (await import("node:crypto")).generateKeyPairSync("ec", { namedCurve: "P-256" });
    const store = new MemoryStore();
    await store.upsertDevice("u1", "aa".repeat(32), true);
    await store.upsertDevice("u1", "bb".repeat(32), false);
    const requests = [];
    const pusher = new Pusher({
      store, log: quiet,
      config: { key: privateKey.export({ type: "pkcs8", format: "pem" }), keyId: "KID", teamId: "TEAM", topic: "com.x" },
      request: async (r) => {
        requests.push(r);
        return r.deviceToken.startsWith("aa") ? { status: 410, reason: "Unregistered" } : { status: 200, reason: "" };
      }
    });
    await pusher.notify("u1", { title: "T", body: "B", reminderId: "r" });
    assert.deepEqual(requests.map((r) => r.host).sort(), ["https://api.push.apple.com", "https://api.sandbox.push.apple.com"]);
    assert.equal(requests[0].headers["apns-push-type"], "alert");
    assert.equal(requests[0].headers["apns-topic"], "com.x");
    assert.match(requests[0].headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    assert.deepEqual(requests[0].payload.aps.alert, { title: "T", body: "B" });
    assert.deepEqual((await store.listDevices("u1")).map((d) => d.token), ["bb".repeat(32)]);
  });
});
