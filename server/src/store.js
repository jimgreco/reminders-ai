import crypto from "node:crypto";
import pg from "pg";

// Two stores with the same contract: MemoryStore for tests and local
// development, PostgresStore for production.
//
// Thread:  { id, userId, reminderId, title, sessionId, status, pendingToolUseId, unread, createdAt, updatedAt }
// Message: { id, threadId, role, text, options, createdAt }
// Op:      { id, userId, threadId, reminderId, kind, payload, createdAt, appliedAt, error }
// Dismissal: { reminderId, until (ISO string, or null for good) }; listed only while in force
// Commitment: { week (a Monday, YYYY-MM-DD), id (c1-c9), text, measure, area, active, reminderId, done, completedAt }

const THREAD_FIELDS = ["title", "sessionId", "status", "pendingToolUseId", "unread"];

export class MemoryStore {
  constructor() {
    this.users = new Map();
    this.identities = new Map();
    this.sessions = new Map();
    this.threads = new Map();
    this.messages = [];
    this.seen = new Set();
    this.ops = [];
    this.devices = new Map();
    this.dismissals = new Map();
    this.commitments = [];
  }

  async upsertUserByIdentity({ provider, subject, email, emailVerified }) {
    const key = `${provider}:${subject}`;
    let user = this.users.get(this.identities.get(key));
    if (!user && emailVerified) {
      const wanted = email.toLowerCase();
      user = [...this.users.values()].find((u) => u.email.toLowerCase() === wanted);
    }
    if (!user) {
      user = { id: crypto.randomUUID(), email, createdAt: new Date().toISOString() };
      this.users.set(user.id, user);
    }
    this.identities.set(key, user.id);
    if (emailVerified) user.email = email;
    return { ...user };
  }

  async getUser(id) {
    const user = this.users.get(id);
    return user ? { ...user } : null;
  }

  async getUserByEmail(email) {
    const wanted = email.toLowerCase();
    const user = [...this.users.values()].find((u) => u.email.toLowerCase() === wanted);
    return user ? { ...user } : null;
  }

  async createSession(userId, tokenHash, expiresAt) {
    this.sessions.set(tokenHash, { userId, expiresAt: new Date(expiresAt) });
  }

  async takeSession(tokenHash) {
    const session = this.sessions.get(tokenHash);
    this.sessions.delete(tokenHash);
    if (!session || session.expiresAt <= new Date()) return null;
    return { userId: session.userId };
  }

  async retireSession(tokenHash, graceUntil) {
    const session = this.sessions.get(tokenHash);
    if (!session || session.expiresAt <= new Date()) return null;
    if (graceUntil < session.expiresAt) session.expiresAt = new Date(graceUntil);
    return { userId: session.userId };
  }

  async deleteUser(userId) {
    this.users.delete(userId);
    for (const [key, id] of this.identities) if (id === userId) this.identities.delete(key);
    for (const [hash, s] of this.sessions) if (s.userId === userId) this.sessions.delete(hash);
    for (const [id, t] of this.threads) if (t.userId === userId) await this.#dropThread(id);
    for (const [token, d] of this.devices) if (d.userId === userId) this.devices.delete(token);
    this.dismissals.delete(userId);
    this.commitments = this.commitments.filter((c) => c.userId !== userId);
  }

  async #dropThread(id) {
    this.threads.delete(id);
    this.messages = this.messages.filter((m) => m.threadId !== id);
    this.ops = this.ops.filter((o) => o.threadId !== id);
    for (const key of this.seen) if (key.startsWith(`${id}:`)) this.seen.delete(key);
  }

  async getThread(userId, reminderId) {
    for (const t of this.threads.values()) {
      if (t.userId === userId && t.reminderId === reminderId) return { ...t };
    }
    return null;
  }

  async getThreadById(id) {
    const t = this.threads.get(id);
    return t ? { ...t } : null;
  }

  async createThread(userId, reminderId, title) {
    const existing = await this.getThread(userId, reminderId);
    if (existing) return existing;
    const now = new Date().toISOString();
    const thread = {
      id: crypto.randomUUID(), userId, reminderId, title, sessionId: null, status: "idle",
      pendingToolUseId: null, unread: false, createdAt: now, updatedAt: now
    };
    this.threads.set(thread.id, thread);
    return { ...thread };
  }

  async updateThread(id, patch) {
    const thread = this.threads.get(id);
    if (!thread) return null;
    for (const field of THREAD_FIELDS) if (field in patch) thread[field] = patch[field];
    thread.updatedAt = new Date().toISOString();
    return { ...thread };
  }

  async listThreads(userId) {
    return [...this.threads.values()].filter((t) => t.userId === userId).map((t) => ({ ...t }));
  }

  async listWorkingThreads() {
    return [...this.threads.values()].filter((t) => t.status === "working").map((t) => ({ ...t }));
  }

  async deleteThread(userId, reminderId) {
    const thread = await this.getThread(userId, reminderId);
    if (thread) await this.#dropThread(thread.id);
    return thread;
  }

  /** Re-keys a thread when its reminder gets a new id (moved to another list).
   *  Returns null when there is no thread; throws "conflict" if `to` has one. */
  async moveThread(userId, from, to) {
    const thread = [...this.threads.values()].find((t) => t.userId === userId && t.reminderId === from);
    if (!thread) return null;
    if (from === to) return { ...thread };
    if (await this.getThread(userId, to)) throw new Error("conflict");
    thread.reminderId = to;
    thread.updatedAt = new Date().toISOString();
    for (const op of this.ops) if (op.threadId === thread.id) op.reminderId = to;
    return { ...thread };
  }

  async addMessage(threadId, role, text, options = null, attachments = null) {
    const message = { id: crypto.randomUUID(), threadId, role, text, options, attachments, createdAt: new Date().toISOString() };
    this.messages.push(message);
    return withoutImageData(message);
  }

  async listMessages(threadId) {
    return this.messages.filter((m) => m.threadId === threadId).map(withoutImageData);
  }

  async getAttachment(userId, attachmentId) {
    for (const m of this.messages) {
      const found = (m.attachments ?? []).find((a) => a.id === attachmentId);
      if (found && this.threads.get(m.threadId)?.userId === userId) return { ...found };
    }
    return null;
  }

  async claimEvent(threadId, eventId) {
    const key = `${threadId}:${eventId}`;
    if (this.seen.has(key)) return false;
    this.seen.add(key);
    return true;
  }

  async addOp({ userId, threadId, reminderId, kind, payload }) {
    const op = {
      id: crypto.randomUUID(), userId, threadId, reminderId, kind, payload,
      createdAt: new Date().toISOString(), appliedAt: null, error: null
    };
    this.ops.push(op);
    return { ...op };
  }

  async listPendingOps(userId) {
    return this.ops.filter((o) => o.userId === userId && !o.appliedAt).map((o) => ({ ...o }));
  }

  async ackOp(userId, id, error) {
    const op = this.ops.find((o) => o.id === id && o.userId === userId);
    if (!op) return null;
    if (!op.appliedAt) {
      op.appliedAt = new Date().toISOString();
      op.error = error;
    }
    return { ...op };
  }

  async upsertDevice(userId, token, sandbox) {
    this.devices.set(token, { token, userId, sandbox });
  }

  async listDevices(userId) {
    return [...this.devices.values()].filter((d) => d.userId === userId).map((d) => ({ ...d }));
  }

  async deleteDevice(token) {
    this.devices.delete(token);
  }

  async listDismissals(userId, now = new Date()) {
    const mine = this.dismissals.get(userId) ?? new Map();
    return [...mine.entries()]
      .filter(([, until]) => until === null || new Date(until) > now)
      .map(([reminderId, until]) => ({ reminderId, until }));
  }

  async setDismissal(userId, reminderId, until) {
    if (!this.dismissals.has(userId)) this.dismissals.set(userId, new Map());
    this.dismissals.get(userId).set(reminderId, until);
    return { reminderId, until };
  }

  async deleteDismissal(userId, reminderId) {
    return this.dismissals.get(userId)?.delete(reminderId) ?? false;
  }

  /** Replaces the accepted set for a week: listed items become active (new ones
   *  are added, wording is updated), the week's others inactive. Returns
   *  whether anything changed. */
  async setCommitments(userId, week, items) {
    let changed = false;
    const mine = this.commitments.filter((c) => c.userId === userId && c.week === week);
    const wanted = new Map(items.map((i) => [i.id, i]));
    for (const row of mine) {
      const item = wanted.get(row.id);
      wanted.delete(row.id);
      const next = item
        ? { text: item.text, measure: item.measure ?? null, area: item.area, active: true }
        : { active: false };
      for (const [key, value] of Object.entries(next)) {
        if (row[key] !== value) {
          row[key] = value;
          changed = true;
        }
      }
    }
    for (const item of wanted.values()) {
      this.commitments.push({
        userId, week, id: item.id, text: item.text, measure: item.measure ?? null, area: item.area,
        active: true, reminderId: null, done: false, completedAt: null
      });
      changed = true;
    }
    return changed;
  }

  /** One week's commitments, or with `since` every week from that Monday on. */
  async listCommitments(userId, { week = null, since = null } = {}) {
    return this.commitments
      .filter((c) => c.userId === userId && (week ? c.week === week : !since || c.week >= since))
      .sort((a, b) => a.week.localeCompare(b.week) || a.id.localeCompare(b.id))
      .map(({ userId: _userId, ...c }) => ({ ...c }));
  }

  /** What the iPhone found: the reminder made for a commitment (null once it
   *  has been removed) and whether it is checked off. Unknown rows are skipped. */
  async reportCommitments(userId, reports) {
    let updated = 0;
    for (const report of reports) {
      const row = this.commitments.find((c) => c.userId === userId && c.week === report.week && c.id === report.id);
      if (!row) continue;
      row.reminderId = report.reminderId;
      row.done = report.done;
      row.completedAt = report.done ? report.completedAt : null;
      updated += 1;
    }
    return updated;
  }

  async health() {
    return true;
  }
}

const iso = (v) => (v === null || v === undefined ? null : new Date(v).toISOString());

function userFromRow(r) {
  return { id: r.id, email: r.email, createdAt: iso(r.created_at) };
}

function threadFromRow(r) {
  return {
    id: r.id, userId: r.user_id, reminderId: r.reminder_id, title: r.title, sessionId: r.agent_session_id,
    status: r.status, pendingToolUseId: r.pending_tool_use_id, unread: r.unread,
    createdAt: iso(r.created_at), updatedAt: iso(r.updated_at)
  };
}

function messageFromRow(r) {
  return {
    id: r.id, threadId: r.thread_id, role: r.role, text: r.text, options: r.options,
    attachments: r.attachments ?? null, createdAt: iso(r.created_at)
  };
}

// Messages are listed with their photos' ids and types; the image data is
// fetched one photo at a time.
function withoutImageData(message) {
  const attachments = message.attachments?.map(({ id, mediaType }) => ({ id, mediaType })) ?? null;
  return { ...message, attachments };
}

function commitmentFromRow(r) {
  return {
    week: r.week, id: r.item_id, text: r.text, measure: r.measure, area: r.area, active: r.active,
    reminderId: r.reminder_id, done: r.done, completedAt: iso(r.completed_at)
  };
}

function opFromRow(r) {
  return {
    id: r.id, userId: r.user_id, threadId: r.thread_id, reminderId: r.reminder_id, kind: r.kind,
    payload: r.payload, createdAt: iso(r.created_at), appliedAt: iso(r.applied_at), error: r.error
  };
}

// Every message column, with the photos' data left out.
const MESSAGE_COLUMNS = `id, thread_id, role, text, options, created_at,
  (SELECT jsonb_agg(a - 'data') FROM jsonb_array_elements(attachments) a) AS attachments`;

const THREAD_COLUMNS = {
  title: "title", sessionId: "agent_session_id", status: "status",
  pendingToolUseId: "pending_tool_use_id", unread: "unread"
};

export class PostgresStore {
  constructor(connectionString, { max = 5 } = {}) {
    this.pool = new pg.Pool({ connectionString, max });
  }

  async close() {
    await this.pool.end();
  }

  async upsertUserByIdentity({ provider, subject, email, emailVerified }) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      // One sign-in at a time decides linking, so two first sign-ins can't create two users.
      await client.query("SELECT pg_advisory_xact_lock(hashtext('reminders-ai-identity'))");
      let { rows } = await client.query(
        `SELECT u.* FROM rai_identities i JOIN rai_users u ON u.id = i.user_id
         WHERE i.provider = $1 AND i.subject = $2`,
        [provider, subject]
      );
      if (!rows[0] && emailVerified) {
        ({ rows } = await client.query(
          "SELECT * FROM rai_users WHERE lower(email) = lower($1) ORDER BY created_at LIMIT 1", [email]
        ));
      }
      if (!rows[0]) {
        ({ rows } = await client.query(
          "INSERT INTO rai_users (id, email) VALUES ($1, $2) RETURNING *", [crypto.randomUUID(), email]
        ));
      }
      const userId = rows[0].id;
      await client.query(
        `INSERT INTO rai_identities (provider, subject, user_id) VALUES ($1, $2, $3)
         ON CONFLICT (provider, subject) DO NOTHING`,
        [provider, subject, userId]
      );
      if (emailVerified) {
        ({ rows } = await client.query("UPDATE rai_users SET email = $2 WHERE id = $1 RETURNING *", [userId, email]));
      }
      await client.query("COMMIT");
      return userFromRow(rows[0]);
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async getUser(id) {
    const { rows } = await this.pool.query("SELECT * FROM rai_users WHERE id = $1", [id]);
    return rows[0] ? userFromRow(rows[0]) : null;
  }

  async getUserByEmail(email) {
    const { rows } = await this.pool.query(
      "SELECT * FROM rai_users WHERE lower(email) = lower($1) ORDER BY created_at LIMIT 1", [email]
    );
    return rows[0] ? userFromRow(rows[0]) : null;
  }

  async createSession(userId, tokenHash, expiresAt) {
    await this.pool.query(
      "INSERT INTO rai_sessions (token_hash, user_id, expires_at) VALUES ($1, $2, $3)",
      [tokenHash, userId, expiresAt]
    );
  }

  async takeSession(tokenHash) {
    const { rows } = await this.pool.query(
      "DELETE FROM rai_sessions WHERE token_hash = $1 RETURNING user_id, expires_at", [tokenHash]
    );
    if (!rows[0] || new Date(rows[0].expires_at) <= new Date()) return null;
    return { userId: rows[0].user_id };
  }

  async retireSession(tokenHash, graceUntil) {
    const { rows } = await this.pool.query(
      `UPDATE rai_sessions SET expires_at = LEAST(expires_at, $2)
        WHERE token_hash = $1 AND expires_at > now() RETURNING user_id`,
      [tokenHash, graceUntil]
    );
    return rows[0] ? { userId: rows[0].user_id } : null;
  }

  async deleteUser(userId) {
    await this.pool.query("DELETE FROM rai_users WHERE id = $1", [userId]);
  }

  async getThread(userId, reminderId) {
    const { rows } = await this.pool.query(
      "SELECT * FROM rai_threads WHERE user_id = $1 AND reminder_id = $2", [userId, reminderId]
    );
    return rows[0] ? threadFromRow(rows[0]) : null;
  }

  async getThreadById(id) {
    const { rows } = await this.pool.query("SELECT * FROM rai_threads WHERE id = $1", [id]);
    return rows[0] ? threadFromRow(rows[0]) : null;
  }

  async createThread(userId, reminderId, title) {
    await this.pool.query(
      `INSERT INTO rai_threads (id, user_id, reminder_id, title) VALUES ($1, $2, $3, $4)
       ON CONFLICT (user_id, reminder_id) DO NOTHING`,
      [crypto.randomUUID(), userId, reminderId, title]
    );
    return this.getThread(userId, reminderId);
  }

  async updateThread(id, patch) {
    const sets = [];
    const values = [id];
    for (const [field, column] of Object.entries(THREAD_COLUMNS)) {
      if (field in patch) {
        values.push(patch[field]);
        sets.push(`${column} = $${values.length}`);
      }
    }
    sets.push("updated_at = now()");
    const { rows } = await this.pool.query(
      `UPDATE rai_threads SET ${sets.join(", ")} WHERE id = $1 RETURNING *`, values
    );
    return rows[0] ? threadFromRow(rows[0]) : null;
  }

  async listThreads(userId) {
    const { rows } = await this.pool.query("SELECT * FROM rai_threads WHERE user_id = $1", [userId]);
    return rows.map(threadFromRow);
  }

  async listWorkingThreads() {
    const { rows } = await this.pool.query("SELECT * FROM rai_threads WHERE status = 'working'");
    return rows.map(threadFromRow);
  }

  async deleteThread(userId, reminderId) {
    const { rows } = await this.pool.query(
      "DELETE FROM rai_threads WHERE user_id = $1 AND reminder_id = $2 RETURNING *", [userId, reminderId]
    );
    return rows[0] ? threadFromRow(rows[0]) : null;
  }

  async moveThread(userId, from, to) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      let rows;
      try {
        ({ rows } = await client.query(
          `UPDATE rai_threads SET reminder_id = $3, updated_at = now()
           WHERE user_id = $1 AND reminder_id = $2 RETURNING *`, [userId, from, to]
        ));
      } catch (error) {
        if (error.code === "23505") throw new Error("conflict");
        throw error;
      }
      if (rows[0]) await client.query("UPDATE rai_ops SET reminder_id = $2 WHERE thread_id = $1", [rows[0].id, to]);
      await client.query("COMMIT");
      return rows[0] ? threadFromRow(rows[0]) : null;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async addMessage(threadId, role, text, options = null, attachments = null) {
    const { rows } = await this.pool.query(
      `INSERT INTO rai_messages (id, thread_id, role, text, options, attachments) VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING ${MESSAGE_COLUMNS}`,
      [crypto.randomUUID(), threadId, role, text, options === null ? null : JSON.stringify(options),
        attachments === null ? null : JSON.stringify(attachments)]
    );
    return messageFromRow(rows[0]);
  }

  async listMessages(threadId) {
    const { rows } = await this.pool.query(
      `SELECT ${MESSAGE_COLUMNS} FROM rai_messages WHERE thread_id = $1 ORDER BY seq`, [threadId]
    );
    return rows.map(messageFromRow);
  }

  async getAttachment(userId, attachmentId) {
    const { rows } = await this.pool.query(
      `SELECT a.value AS attachment
         FROM rai_messages m
         JOIN rai_threads t ON t.id = m.thread_id
         CROSS JOIN LATERAL jsonb_array_elements(m.attachments) a
        WHERE t.user_id = $1 AND m.attachments IS NOT NULL AND a.value->>'id' = $2
        LIMIT 1`,
      [userId, attachmentId]
    );
    return rows[0]?.attachment ?? null;
  }

  async claimEvent(threadId, eventId) {
    const { rowCount } = await this.pool.query(
      "INSERT INTO rai_seen_events (thread_id, event_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      [threadId, eventId]
    );
    return rowCount === 1;
  }

  async addOp({ userId, threadId, reminderId, kind, payload }) {
    const { rows } = await this.pool.query(
      `INSERT INTO rai_ops (id, user_id, thread_id, reminder_id, kind, payload)
       VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
      [crypto.randomUUID(), userId, threadId, reminderId, kind, JSON.stringify(payload)]
    );
    return opFromRow(rows[0]);
  }

  async listPendingOps(userId) {
    const { rows } = await this.pool.query(
      "SELECT * FROM rai_ops WHERE user_id = $1 AND applied_at IS NULL ORDER BY seq", [userId]
    );
    return rows.map(opFromRow);
  }

  async ackOp(userId, id, error) {
    const { rows } = await this.pool.query(
      `UPDATE rai_ops SET applied_at = COALESCE(applied_at, now()),
         error = CASE WHEN applied_at IS NULL THEN $3 ELSE error END
       WHERE id = $1 AND user_id = $2 RETURNING *`,
      [id, userId, error]
    );
    return rows[0] ? opFromRow(rows[0]) : null;
  }

  async upsertDevice(userId, token, sandbox) {
    await this.pool.query(
      `INSERT INTO rai_devices (token, user_id, sandbox) VALUES ($1, $2, $3)
       ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, sandbox = EXCLUDED.sandbox, updated_at = now()`,
      [token, userId, sandbox]
    );
  }

  async listDevices(userId) {
    const { rows } = await this.pool.query("SELECT token, user_id, sandbox FROM rai_devices WHERE user_id = $1", [userId]);
    return rows.map((r) => ({ token: r.token, userId: r.user_id, sandbox: r.sandbox }));
  }

  async deleteDevice(token) {
    await this.pool.query("DELETE FROM rai_devices WHERE token = $1", [token]);
  }

  async listDismissals(userId, now = new Date()) {
    const { rows } = await this.pool.query(
      `SELECT reminder_id, dismissed_until FROM rai_plan_dismissals
       WHERE user_id = $1 AND (dismissed_until IS NULL OR dismissed_until > $2)
       ORDER BY created_at`, [userId, now]
    );
    return rows.map((r) => ({ reminderId: r.reminder_id, until: r.dismissed_until ? new Date(r.dismissed_until).toISOString() : null }));
  }

  async setDismissal(userId, reminderId, until) {
    await this.pool.query(
      `INSERT INTO rai_plan_dismissals (user_id, reminder_id, dismissed_until) VALUES ($1, $2, $3)
       ON CONFLICT (user_id, reminder_id) DO UPDATE SET dismissed_until = EXCLUDED.dismissed_until, created_at = now()`,
      [userId, reminderId, until]
    );
    return { reminderId, until };
  }

  async deleteDismissal(userId, reminderId) {
    const { rowCount } = await this.pool.query(
      "DELETE FROM rai_plan_dismissals WHERE user_id = $1 AND reminder_id = $2", [userId, reminderId]
    );
    return rowCount > 0;
  }

  async setCommitments(userId, week, items) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      let changed = 0;
      for (const item of items) {
        const { rowCount } = await client.query(
          `INSERT INTO rai_commitments (user_id, week, item_id, text, measure, area) VALUES ($1, $2, $3, $4, $5, $6)
           ON CONFLICT (user_id, week, item_id) DO UPDATE
             SET text = EXCLUDED.text, measure = EXCLUDED.measure, area = EXCLUDED.area, active = true, updated_at = now()
           WHERE (rai_commitments.text, rai_commitments.measure, rai_commitments.area, rai_commitments.active)
             IS DISTINCT FROM (EXCLUDED.text, EXCLUDED.measure, EXCLUDED.area, true)`,
          [userId, week, item.id, item.text, item.measure ?? null, item.area]
        );
        changed += rowCount;
      }
      const { rowCount } = await client.query(
        `UPDATE rai_commitments SET active = false, updated_at = now()
         WHERE user_id = $1 AND week = $2 AND active AND NOT (item_id = ANY($3::text[]))`,
        [userId, week, items.map((i) => i.id)]
      );
      await client.query("COMMIT");
      return changed + rowCount > 0;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async listCommitments(userId, { week = null, since = null } = {}) {
    const { rows } = await this.pool.query(
      `SELECT to_char(week, 'YYYY-MM-DD') AS week, item_id, text, measure, area, active, reminder_id, done, completed_at
         FROM rai_commitments
        WHERE user_id = $1 AND ($2::date IS NULL OR week = $2) AND ($2::date IS NOT NULL OR $3::date IS NULL OR week >= $3)
        ORDER BY week, item_id`,
      [userId, week, since]
    );
    return rows.map(commitmentFromRow);
  }

  async reportCommitments(userId, reports) {
    let updated = 0;
    for (const report of reports) {
      const { rowCount } = await this.pool.query(
        `UPDATE rai_commitments SET reminder_id = $4, done = $5, completed_at = $6, updated_at = now()
         WHERE user_id = $1 AND week = $2 AND item_id = $3`,
        [userId, report.week, report.id, report.reminderId, report.done, report.done ? report.completedAt : null]
      );
      updated += rowCount;
    }
    return updated;
  }

  async health() {
    await this.pool.query("SELECT 1 FROM rai_threads LIMIT 1");
    return true;
  }
}
