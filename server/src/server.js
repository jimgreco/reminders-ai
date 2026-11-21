import http from "node:http";
import Anthropic from "@anthropic-ai/sdk";
import { createApp, loadConfig } from "./app.js";
import { Assistant } from "./agent.js";
import { FakeAgentClient } from "./fake-agent.js";
import { FakePlanClient, Planner } from "./planner.js";
import { Pusher, loadPushConfig } from "./push.js";
import { MemoryStore, PostgresStore } from "./store.js";

const config = loadConfig();
const store = config.databaseURL ? new PostgresStore(config.databaseURL) : new MemoryStore();
if (!config.databaseURL) console.warn("DATABASE_URL is not set: using an in-memory store (data is lost on restart)");

const pushConfig = loadPushConfig(process.env);
const push = pushConfig ? new Pusher({ store, config: pushConfig }) : null;
if (!push) console.warn("APNs is not configured: no push notifications");

// The SDK reads ANTHROPIC_API_KEY from the environment.
let client = config.agentId && config.environmentId && process.env.ANTHROPIC_API_KEY ? new Anthropic() : null;
if (!client && !config.production && process.env.REMINDERS_AI_FAKE_AGENT === "1") {
  console.warn("REMINDERS_AI_FAKE_AGENT=1: the assistant plays a fixed script, no model is called");
  client = new FakeAgentClient();
  config.agentId ||= "fake";
  config.environmentId ||= "fake";
}
if (!client) console.warn("AGENT_ID, AGENT_ENVIRONMENT_ID or ANTHROPIC_API_KEY is not set: the assistant is off");

const assistant = new Assistant({ store, client, config, push });

// Plan my day needs only the API key, not the agent.
let planClient = null;
if (process.env.ANTHROPIC_API_KEY) planClient = client instanceof Anthropic ? client : new Anthropic();
else if (!config.production && process.env.REMINDERS_AI_FAKE_AGENT === "1") planClient = new FakePlanClient();
const planner = new Planner({ client: planClient });
assistant.start();

const server = http.createServer(createApp({ store, config, assistant, planner, push }));
server.requestTimeout = 60_000;
server.headersTimeout = 15_000;
server.listen(config.port, () => console.log(`reminders-ai listening on :${config.port} (build ${config.build})`));

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    assistant.close();
    server.close(() => Promise.resolve(store.close?.()).finally(() => process.exit(0)));
    setTimeout(() => process.exit(0), 5_000).unref();
  });
}
