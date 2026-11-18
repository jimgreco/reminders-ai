import crypto from "node:crypto";
import appleSignin from "apple-signin-auth";
import { OAuth2Client } from "google-auth-library";

const ACCESS_TTL_MS = 15 * 60_000;
const REFRESH_TTL_MS = 120 * 24 * 60 * 60_000;
const MAX_BODY_BYTES = 256 * 1024;
export const LIMITS = {
  messageChars: 8000, titleChars: 500, notesChars: 20_000,
  // Photos on one message. The app sends JPEGs of at most 1568 px, well under this.
  images: 4, imageBytes: 3 * 1024 * 1024
};
// A message with photos: four images as base64, plus the text and reminder.
const MAX_MESSAGE_BYTES = Math.ceil(LIMITS.images * LIMITS.imageBytes * 4 / 3) + MAX_BODY_BYTES;
const IMAGE_TYPES = { "image/jpeg": [0xff, 0xd8, 0xff], "image/png": [0x89, 0x50, 0x4e, 0x47], "image/gif": [0x47, 0x49, 0x46], "image/webp": [0x52, 0x49, 0x46, 0x46] };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PRIORITIES = ["none", "low", "medium", "high"];

export function sha256Hex(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function loadConfig(env = process.env) {
  const production = env.NODE_ENV === "production";
  const list = (v) => String(v || "").split(",").map((s) => s.trim()).filter(Boolean);
  const config = {
    production,
    port: Number(env.PORT || 8792),
    databaseURL: env.DATABASE_URL || "",
    sessionSecret: env.SESSION_SECRET || "",
    appleBundleId: env.APPLE_BUNDLE_ID || "",
    // The iOS app's Google OAuth client id(s), the identity-token audience.
    googleClientIds: list(env.GOOGLE_CLIENT_ID),
    allowedEmails: list(env.ALLOWED_EMAILS).map((e) => e.toLowerCase()),
    allowedAppleSubs: list(env.ALLOWED_APPLE_SUBS),
    trustProxyHops: Number(env.TRUST_PROXY_HOPS || 0),
    build: env.APP_BUILD || "dev",
    devSignIn: env.REMINDERS_AI_DEV_SIGNIN === "1",
    // Claude Managed Agents: ids printed by scripts/setup-agent.js.
    agentId: env.AGENT_ID || "",
    environmentId: env.AGENT_ENVIRONMENT_ID || "",
    // Spending cap per agent session, in cents at list prices. 0 = no cap.
    sessionBudgetCents: Number(env.SESSION_BUDGET_CENTS ?? 500)
  };
  if (config.sessionSecret.length < 32) throw new Error("SESSION_SECRET must be at least 32 characters");
  if (!Number.isInteger(config.sessionBudgetCents) || config.sessionBudgetCents < 0) {
    throw new Error("SESSION_BUDGET_CENTS must be a whole number of cents");
  }
  if (production) {
    if (!config.databaseURL) throw new Error("DATABASE_URL is required in production");
    if (config.devSignIn) throw new Error("REMINDERS_AI_DEV_SIGNIN is not allowed in production");
    if (!config.allowedEmails.length && !config.allowedAppleSubs.length) {
      throw new Error("ALLOWED_EMAILS or ALLOWED_APPLE_SUBS is required in production");
    }
    if (!config.agentId || !config.environmentId) throw new Error("AGENT_ID and AGENT_ENVIRONMENT_ID are required in production");
  }
  return config;
}

function b64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

function send(response, status, body, headers = {}) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    ...headers
  });
  response.end(JSON.stringify(body));
}

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function readJSON(request, maxBytes = MAX_BODY_BYTES) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBytes) throw new HttpError(413, "body too large");
    chunks.push(chunk);
  }
  if (!size) return {};
  const type = String(request.headers["content-type"] || "");
  if (!type.startsWith("application/json")) throw new HttpError(415, "content-type must be application/json");
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value;
  } catch {
    throw new HttpError(400, "invalid JSON");
  }
}

// The reminder as the iPhone sees it when the person sends a message.
export function validateReminder(value) {
  const r = value && typeof value === "object" ? value : {};
  const errors = [];
  const optionalText = (field, max) => {
    if (r[field] === undefined || r[field] === null) return "";
    if (typeof r[field] !== "string" || r[field].length > max) errors.push(`${field} must be text of at most ${max} characters`);
    return typeof r[field] === "string" ? r[field] : "";
  };
  if (typeof r.title !== "string" || !r.title.trim() || r.title.length > LIMITS.titleChars) {
    errors.push(`reminder.title is required, at most ${LIMITS.titleChars} characters`);
  }
  const reminder = {
    title: typeof r.title === "string" ? r.title.trim() : "",
    notes: optionalText("notes", LIMITS.notesChars),
    list: optionalText("list", 200),
    due: optionalText("due", 40),
    timeZone: optionalText("timeZone", 64),
    now: optionalText("now", 40),
    priority: PRIORITIES.includes(r.priority) ? r.priority : "none",
    completed: r.completed === true
  };
  if (errors.length) throw new HttpError(400, errors.join("; "));
  return reminder;
}

function threadSummary(thread) {
  return {
    reminderId: thread.reminderId,
    title: thread.title,
    status: thread.status,
    unread: thread.unread,
    updatedAt: thread.updatedAt
  };
}

// Photos sent with a message: an image type the model reads, real image bytes
// of that type, and a size cap.
export function validateImages(value) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.length > LIMITS.images) {
    throw new HttpError(400, `images must be a list of at most ${LIMITS.images}`);
  }
  return value.map((image, index) => {
    const mediaType = image?.mediaType;
    const magic = IMAGE_TYPES[mediaType];
    if (!magic || typeof image.data !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(image.data)) {
      throw new HttpError(400, `images[${index}] must be a JPEG, PNG, GIF or WebP in base64`);
    }
    const bytes = Buffer.from(image.data, "base64");
    if (bytes.length > LIMITS.imageBytes) throw new HttpError(413, `images[${index}] is larger than 3 MB`);
    if (!magic.every((b, i) => bytes[i] === b)) throw new HttpError(400, `images[${index}] is not a ${mediaType}`);
    return { id: crypto.randomUUID(), mediaType, data: image.data };
  });
}

function publicMessage(m) {
  return {
    id: m.id, role: m.role, text: m.text, options: m.options ?? null,
    attachments: m.attachments?.length ? m.attachments.map(({ id, mediaType }) => ({ id, mediaType })) : null,
    createdAt: m.createdAt
  };
}

export function createApp({ store, config, assistant, verifyAppleToken, verifyGoogleToken, now = () => new Date() }) {
  const buckets = new Map();

  verifyAppleToken ??= async (identityToken) =>
    appleSignin.verifyIdToken(identityToken, { audience: config.appleBundleId, ignoreExpiration: false });

  const googleClient = new OAuth2Client();
  verifyGoogleToken ??= async (idToken) => {
    const ticket = await googleClient.verifyIdToken({ idToken, audience: config.googleClientIds });
    return ticket.getPayload();
  };

  function clientIP(request) {
    const socket = request.socket?.remoteAddress || "unknown";
    if (!config.trustProxyHops) return socket;
    const hops = String(request.headers["x-forwarded-for"] || "").split(",").map((s) => s.trim()).filter(Boolean);
    return hops[hops.length - config.trustProxyHops] || socket;
  }

  function limited(request, name, limit, windowMs) {
    const key = `${name}:${clientIP(request)}`;
    const t = now().getTime();
    let bucket = buckets.get(key);
    if (!bucket || bucket.resetAt <= t) {
      bucket = { count: 0, resetAt: t + windowMs };
      buckets.set(key, bucket);
    }
    bucket.count += 1;
    if (buckets.size > 10_000) {
      for (const [k, b] of buckets) if (b.resetAt <= t) buckets.delete(k);
    }
    return bucket.count > limit ? Math.ceil((bucket.resetAt - t) / 1000) : 0;
  }

  function sign(payload) {
    return b64url(crypto.createHmac("sha256", config.sessionSecret).update(payload).digest());
  }

  function accessToken(userId) {
    const payload = b64url(JSON.stringify({ v: 1, sub: userId, exp: now().getTime() + ACCESS_TTL_MS }));
    return `${payload}.${sign(payload)}`;
  }

  function verifyAccessToken(token) {
    const [payload, mac, extra] = String(token || "").split(".");
    if (!payload || !mac || extra !== undefined) return null;
    const expected = Buffer.from(sign(payload));
    const given = Buffer.from(mac);
    if (expected.length !== given.length || !crypto.timingSafeEqual(expected, given)) return null;
    try {
      const claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
      if (claims.v !== 1 || typeof claims.sub !== "string" || claims.exp <= now().getTime()) return null;
      return claims.sub;
    } catch {
      return null;
    }
  }

  async function issueSession(user) {
    const refreshToken = b64url(crypto.randomBytes(32));
    await store.createSession(user.id, sha256Hex(refreshToken), new Date(now().getTime() + REFRESH_TTL_MS));
    return {
      accessToken: accessToken(user.id),
      accessTokenExpiresIn: ACCESS_TTL_MS / 1000,
      refreshToken,
      user: { id: user.id, email: user.email }
    };
  }

  function isAllowed(provider, sub, email) {
    if (provider === "apple" && config.allowedAppleSubs.includes(sub)) return true;
    if (email && config.allowedEmails.includes(email.toLowerCase())) return true;
    return !config.production && !config.allowedEmails.length && !config.allowedAppleSubs.length;
  }

  // Shared by Apple and Google: only a verified email counts, and only allowed accounts get in.
  async function signInWith(response, provider, claims) {
    const subject = String(claims.sub).slice(0, 255);
    const verified = claims.email_verified === true || claims.email_verified === "true";
    const email = claims.email && verified ? String(claims.email) : "";
    if (!isAllowed(provider, subject, email)) {
      // The sub is the provider's opaque user id; for Apple the owner can copy it into ALLOWED_APPLE_SUBS.
      console.warn(`sign-in refused for ${provider} sub ${subject.slice(0, 64)}`);
      return send(response, 403, { error: "this app is private" });
    }
    const user = await store.upsertUserByIdentity({
      provider,
      subject,
      email: email || `${subject}@${provider}.invalid`,
      emailVerified: Boolean(email)
    });
    return send(response, 200, await issueSession(user));
  }

  async function authenticate(request) {
    const match = String(request.headers.authorization || "").match(/^Bearer (.+)$/);
    const userId = match ? verifyAccessToken(match[1]) : null;
    const user = userId ? await store.getUser(userId) : null;
    if (!user) throw new HttpError(401, "sign in required");
    return user;
  }

  async function threadBody(thread) {
    const messages = await store.listMessages(thread.id);
    return { ...threadSummary(thread), messages: messages.map(publicMessage) };
  }

  async function route(request, response) {
    const url = new URL(request.url, "http://reminders-ai.local");
    const path = url.pathname;
    const method = request.method;

    if (method === "GET" && path === "/health") {
      try {
        await store.health();
        return send(response, 200, { ok: true, status: "ok", db: true, build: config.build });
      } catch {
        return send(response, 503, { ok: false, status: "error", db: false, build: config.build });
      }
    }

    if (method === "POST" && path === "/auth/apple") {
      const retry = limited(request, "auth", 20, 15 * 60_000);
      if (retry) return send(response, 429, { error: "rate limited" }, { "retry-after": String(retry) });
      if (!config.appleBundleId) return send(response, 503, { error: "Apple sign-in is not configured" });
      const body = await readJSON(request);
      if (typeof body.identityToken !== "string" || body.identityToken.length > 8192) {
        throw new HttpError(400, "identityToken required");
      }
      let claims;
      try {
        claims = await verifyAppleToken(body.identityToken);
      } catch {
        claims = null;
      }
      if (!claims?.sub) return send(response, 401, { error: "invalid Apple token" });
      return signInWith(response, "apple", claims);
    }

    if (method === "POST" && path === "/auth/google") {
      const retry = limited(request, "auth", 20, 15 * 60_000);
      if (retry) return send(response, 429, { error: "rate limited" }, { "retry-after": String(retry) });
      if (!config.googleClientIds.length) return send(response, 503, { error: "Google sign-in is not configured" });
      const body = await readJSON(request);
      if (typeof body.idToken !== "string" || body.idToken.length > 8192) throw new HttpError(400, "idToken required");
      let claims;
      try {
        claims = await verifyGoogleToken(body.idToken);
      } catch {
        claims = null;
      }
      if (!claims?.sub) return send(response, 401, { error: "invalid Google token" });
      return signInWith(response, "google", claims);
    }

    if (method === "POST" && path === "/auth/dev") {
      if (config.production || !config.devSignIn) return send(response, 404, { error: "not found" });
      const body = await readJSON(request);
      const email = typeof body.email === "string" && body.email ? body.email : "dev@example.test";
      const user = await store.upsertUserByIdentity({ provider: "dev", subject: email, email, emailVerified: true });
      return send(response, 200, await issueSession(user));
    }

    if (method === "POST" && path === "/auth/refresh") {
      const retry = limited(request, "refresh", 60, 15 * 60_000);
      if (retry) return send(response, 429, { error: "rate limited" }, { "retry-after": String(retry) });
      const body = await readJSON(request);
      const session = typeof body.refreshToken === "string" && body.refreshToken.length <= 200
        ? await store.takeSession(sha256Hex(body.refreshToken))
        : null;
      const user = session ? await store.getUser(session.userId) : null;
      if (!user) return send(response, 401, { error: "invalid refresh token" });
      return send(response, 200, await issueSession(user));
    }

    if (method === "POST" && path === "/auth/signout") {
      const body = await readJSON(request);
      if (typeof body.refreshToken === "string" && body.refreshToken.length <= 200) {
        await store.takeSession(sha256Hex(body.refreshToken));
      }
      return send(response, 200, { ok: true });
    }

    if (!path.startsWith("/api/")) return send(response, 404, { error: "not found" });

    const retry = limited(request, "api", 1200, 15 * 60_000);
    if (retry) return send(response, 429, { error: "rate limited" }, { "retry-after": String(retry) });
    const user = await authenticate(request);

    if (method === "GET" && path === "/api/me") {
      return send(response, 200, { id: user.id, email: user.email, assistant: assistant.configured });
    }

    // Everything the app needs on launch or after a push: which reminders
    // have a thread and its state, and the edits waiting to be applied.
    if (method === "GET" && path === "/api/sync") {
      const [threads, ops] = await Promise.all([store.listThreads(user.id), store.listPendingOps(user.id)]);
      return send(response, 200, {
        threads: threads.map(threadSummary),
        ops: ops.map((o) => ({ id: o.id, reminderId: o.reminderId, kind: o.kind, payload: o.payload, createdAt: o.createdAt }))
      });
    }

    const ackMatch = path.match(/^\/api\/ops\/([^/]+)\/ack$/);
    if (ackMatch && method === "POST") {
      if (!UUID.test(ackMatch[1])) throw new HttpError(400, "op id must be a UUID");
      const body = await readJSON(request);
      const error = typeof body.error === "string" && body.error ? body.error.slice(0, 500) : null;
      const op = await store.ackOp(user.id, ackMatch[1].toLowerCase(), error);
      if (!op) return send(response, 404, { error: "not found" });
      return send(response, 200, { ok: true });
    }

    if (method === "POST" && path === "/api/devices") {
      const body = await readJSON(request);
      if (typeof body.token !== "string" || !/^[0-9a-f]{64,200}$/.test(body.token)) throw new HttpError(400, "token must be a hex device token");
      await store.upsertDevice(user.id, body.token, body.sandbox === true);
      return send(response, 200, { ok: true });
    }

    const attachmentMatch = path.match(/^\/api\/attachments\/([0-9a-f-]{36})$/i);
    if (method === "GET" && attachmentMatch) {
      const attachment = await store.getAttachment(user.id, attachmentMatch[1].toLowerCase());
      if (!attachment) return send(response, 404, { error: "not found" });
      response.writeHead(200, {
        "content-type": attachment.mediaType,
        "cache-control": "private, max-age=31536000, immutable",
        "x-content-type-options": "nosniff",
        "content-security-policy": "default-src 'none'"
      });
      return response.end(Buffer.from(attachment.data, "base64"));
    }

    const threadMatch = path.match(/^\/api\/threads\/([^/]+)(\/(messages|stop|read|move))?$/);
    if (threadMatch) {
      let reminderId;
      try {
        reminderId = decodeURIComponent(threadMatch[1]);
      } catch {
        throw new HttpError(400, "bad reminder id");
      }
      if (!reminderId || reminderId.length > 255) throw new HttpError(400, "bad reminder id");
      const action = threadMatch[3];

      if (method === "POST" && action === "messages") {
        if (!assistant.configured) return send(response, 503, { error: "The assistant isn't set up on the server yet." });
        const body = await readJSON(request, MAX_MESSAGE_BYTES);
        const text = typeof body.text === "string" ? body.text.trim() : "";
        const images = validateImages(body.images);
        if ((!text && !images.length) || text.length > LIMITS.messageChars) {
          throw new HttpError(400, `text or a photo is required; text at most ${LIMITS.messageChars} characters`);
        }
        const reminder = validateReminder(body.reminder);
        const thread = await assistant.post(user, reminderId, text, reminder, images);
        return send(response, 200, await threadBody(thread));
      }

      let thread = await store.getThread(user.id, reminderId);
      if (!thread) return send(response, 404, { error: "no thread for this reminder" });

      if (method === "GET" && !action) {
        if (thread.status === "working" && assistant.configured) {
          thread = (await assistant.sync(thread.id).catch(() => null)) ?? thread;
        }
        return send(response, 200, await threadBody(thread));
      }
      if (method === "POST" && action === "read") {
        if (thread.unread) thread = await store.updateThread(thread.id, { unread: false });
        return send(response, 200, threadSummary(thread));
      }
      if (method === "POST" && action === "move") {
        // The reminder got a new id, as EventKit does when it moves to another list.
        const body = await readJSON(request);
        const to = typeof body.to === "string" ? body.to : "";
        if (!to || to.length > 255) throw new HttpError(400, "to required");
        try {
          thread = await store.moveThread(user.id, reminderId, to);
        } catch (error) {
          if (error.message === "conflict") throw new HttpError(409, "that reminder already has a conversation");
          throw error;
        }
        return send(response, 200, threadSummary(thread));
      }
      if (method === "POST" && action === "stop") {
        if (assistant.configured) await assistant.stop(thread);
        return send(response, 200, threadSummary(thread));
      }
      if (method === "DELETE" && !action) {
        if (assistant.configured) await assistant.stop(thread).catch(() => {});
        await store.deleteThread(user.id, reminderId);
        return send(response, 200, { ok: true });
      }
    }

    if (method === "DELETE" && path === "/api/account") {
      await store.deleteUser(user.id);
      return send(response, 200, { ok: true });
    }

    return send(response, 404, { error: "not found" });
  }

  return async function handler(request, response) {
    try {
      await route(request, response);
    } catch (error) {
      if (error instanceof HttpError) return send(response, error.status, { error: error.message });
      console.error("request failed:", error.message);
      if (!response.headersSent) send(response, 500, { error: "internal" });
    }
  };
}
