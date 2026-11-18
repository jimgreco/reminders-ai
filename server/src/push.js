import crypto from "node:crypto";
import http2 from "node:http2";

// Apple Push Notification service, token-based (.p8 key). A push tells the
// person the agent has a result or a question, and wakes the app so it can
// apply the reminder edits the agent queued.

const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };
const TOKEN_TTL_MS = 40 * 60_000; // Apple accepts a provider token for up to an hour

export function loadPushConfig(env) {
  const key = String(env.APNS_PRIVATE_KEY || "").replace(/\\n/g, "\n").trim();
  const config = { key, keyId: env.APNS_KEY_ID || "", teamId: env.APNS_TEAM_ID || "", topic: env.APPLE_BUNDLE_ID || "" };
  const set = [config.key, config.keyId, config.teamId].filter(Boolean).length;
  if (set !== 0 && (set !== 3 || !config.topic)) {
    throw new Error("APNS_PRIVATE_KEY, APNS_KEY_ID, APNS_TEAM_ID and APPLE_BUNDLE_ID must be set together");
  }
  return set === 3 ? config : null;
}

export function buildPayload({ title, body, reminderId }) {
  // No body: a silent push that only wakes the app to apply queued edits.
  const aps = body
    ? { alert: { title, body }, sound: "default", "content-available": 1, "thread-id": reminderId }
    : { "content-available": 1 };
  return { aps, reminderId };
}

export class Pusher {
  constructor({ store, config, log = console, request = sendToApple }) {
    this.store = store;
    this.config = config;
    this.log = log;
    this.request = request;
    this.token = null;
    this.tokenAt = 0;
  }

  #providerToken() {
    const now = Date.now();
    if (this.token && now - this.tokenAt < TOKEN_TTL_MS) return this.token;
    const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
    const head = `${part({ alg: "ES256", kid: this.config.keyId })}.${part({ iss: this.config.teamId, iat: Math.floor(now / 1000) })}`;
    const signature = crypto.sign("sha256", Buffer.from(head), { key: this.config.key, dsaEncoding: "ieee-p1363" });
    this.token = `${head}.${signature.toString("base64url")}`;
    this.tokenAt = now;
    return this.token;
  }

  async notify(userId, message) {
    const devices = await this.store.listDevices(userId);
    const payload = buildPayload(message);
    await Promise.all(devices.map(async (device) => {
      const result = await this.request({
        host: device.sandbox ? HOSTS.sandbox : HOSTS.production,
        deviceToken: device.token,
        headers: {
          authorization: `bearer ${this.#providerToken()}`,
          "apns-topic": this.config.topic,
          "apns-push-type": message.body ? "alert" : "background",
          "apns-priority": message.body ? "10" : "5"
        },
        payload
      });
      if (result.status === 410 || result.reason === "BadDeviceToken" || result.reason === "Unregistered") {
        await this.store.deleteDevice(device.token);
      } else if (result.status !== 200) {
        this.log.warn(`APNs returned ${result.status} ${result.reason || ""}`.trim());
      }
    }));
  }
}

function sendToApple({ host, deviceToken, headers, payload }) {
  return new Promise((resolve, reject) => {
    const client = http2.connect(host);
    const fail = (error) => {
      client.destroy();
      reject(error);
    };
    client.on("error", fail);
    const request = client.request({ ":method": "POST", ":path": `/3/device/${deviceToken}`, ...headers });
    request.setTimeout(10_000, () => fail(new Error("APNs timed out")));
    let status = 0;
    let data = "";
    request.on("response", (h) => { status = h[":status"]; });
    request.setEncoding("utf8");
    request.on("data", (chunk) => { data += chunk; });
    request.on("error", fail);
    request.on("end", () => {
      client.close();
      let reason = "";
      try {
        reason = data ? JSON.parse(data).reason : "";
      } catch {
        reason = "";
      }
      resolve({ status, reason });
    });
    request.end(JSON.stringify(payload));
  });
}
