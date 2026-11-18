// A scripted stand-in for Claude Managed Agents, for running the app locally
// without an API key (REMINDERS_AI_FAKE_AGENT=1, never in production). It
// plays one fixed exchange: a search, a question, two reminder edits, a reply.

export class FakeAgentClient {
  constructor({ delayMs = 1500 } = {}) {
    this.sessions = new Map();
    this.delayMs = delayMs;
    this.beta = {
      sessions: {
        create: async () => {
          const id = `fake_${this.sessions.size + 1}`;
          this.sessions.set(id, { status: "idle", events: [], pendingTools: 0, asked: false });
          return { id };
        },
        retrieve: async (id) => ({ id, status: this.sessions.get(id).status }),
        events: {
          send: async (id, { events }) => {
            for (const event of events) this.#receive(id, event);
            return {};
          },
          list: (id) => {
            const events = [...this.sessions.get(id).events];
            return { async *[Symbol.asyncIterator]() { yield* events; } };
          }
        }
      }
    };
  }

  #emit(session, ...events) {
    for (const event of events) {
      session.events.push({ id: `sevt_${session.events.length + 1}`, processed_at: new Date().toISOString(), ...event });
    }
  }

  #later(session, ...events) {
    session.status = "running";
    this.#emit(session, { type: "session.status_running" });
    setTimeout(() => {
      this.#emit(session, ...events);
      session.status = "idle";
    }, this.delayMs).unref();
  }

  #receive(id, event) {
    const session = this.sessions.get(id);
    const says = (text) => ({ type: "agent.message", content: [{ type: "text", text }] });
    const idle = (type) => ({ type: "session.status_idle", stop_reason: { type } });
    const tool = (name, input) => ({ type: "agent.custom_tool_use", name, input });

    if (event.type === "user.message" && !session.asked) {
      session.asked = true;
      this.#later(session,
        { type: "agent.tool_use", name: "web_search", input: { query: "how to get this done" }, evaluated_permission: "allow" },
        says("I looked into this. There are two reasonable ways to go, and they differ mostly in **time versus cost**."),
        tool("ask_user", { question: "Which matters more for this one?", options: ["Fastest", "Cheapest"] }),
        idle("requires_action"));
    } else if (event.type === "user.message") {
      this.#later(session, says(`(Scripted reply) Noted: "${event.content[0].text.split("\n").pop()}".`), idle("end_turn"));
    } else if (event.type === "user.custom_tool_result" && session.pendingTools === 0) {
      const choice = event.content?.[0]?.text ?? "that";
      session.pendingTools = 2;
      this.#later(session,
        tool("update_reminder", { notes: `Plan: going with "${choice}".\nNext step: book it this week.` }),
        tool("create_reminder", { title: "Book the appointment", priority: "medium" }),
        idle("requires_action"));
    } else if (event.type === "user.custom_tool_result") {
      session.pendingTools -= 1;
      if (session.pendingTools === 0) {
        this.#later(session,
          says("Done. I put the plan in the reminder's notes and added a follow-up, **Book the appointment**. Tell me when it's booked and I'll line up what comes after."),
          idle("end_turn"));
      }
    } else if (event.type === "user.interrupt") {
      this.#emit(session, idle("end_turn"));
      session.status = "idle";
    }
  }
}
