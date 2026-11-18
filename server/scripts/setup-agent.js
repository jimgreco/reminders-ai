// One-time setup (and later updates) of the Claude Managed Agents objects this
// server uses. Run by the owner, never by the server:
//
//   ANTHROPIC_API_KEY=... AGENT_NETWORKING=unrestricted node scripts/setup-agent.js
//
// Prints AGENT_ID and AGENT_ENVIRONMENT_ID for the server's environment file.
// Run it again with those two set to push a changed prompt or tool list to the
// existing agent (a new agent version; sessions already running keep theirs).
//
// AGENT_NETWORKING must be chosen explicitly:
//   unrestricted  web search and web fetch can reach any public site. This is
//                 what open-ended research needs. The agent has no shell or
//                 file tools and its sandbox holds no secrets.
//   limited       nothing is reachable until hosts are listed in
//                 AGENT_ALLOWED_HOSTS (comma-separated); search results and
//                 fetches outside that list come back empty.

import Anthropic from "@anthropic-ai/sdk";
import { agentDefinition } from "../src/agent.js";

const model = process.env.AGENT_MODEL || "claude-opus-5-5";
const networking = process.env.AGENT_NETWORKING;
if (networking !== "unrestricted" && networking !== "limited") {
  console.error("Set AGENT_NETWORKING to unrestricted or limited (see the comment at the top of this file).");
  process.exit(2);
}

const client = new Anthropic();
const definition = agentDefinition(model);

let environmentId = process.env.AGENT_ENVIRONMENT_ID;
if (!environmentId) {
  const hosts = String(process.env.AGENT_ALLOWED_HOSTS || "").split(",").map((h) => h.trim()).filter(Boolean);
  const environment = await client.beta.environments.create({
    name: "reminders-ai",
    config: {
      type: "cloud",
      networking: networking === "unrestricted" ? { type: "unrestricted" } : { type: "limited", allowed_hosts: hosts }
    }
  });
  environmentId = environment.id;
}

let agent;
if (process.env.AGENT_ID) {
  agent = await client.beta.agents.update(process.env.AGENT_ID, definition);
} else {
  agent = await client.beta.agents.create(definition);
}

console.log(`AGENT_ID=${agent.id}`);
console.log(`AGENT_ENVIRONMENT_ID=${environmentId}`);
console.log(`# agent version ${agent.version}, model ${model}`);
