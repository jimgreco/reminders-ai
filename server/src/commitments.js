import crypto from "node:crypto";

// Commitments from the weekly review site. Each Sunday review proposes a few
// actions for the coming week; the ones the owner accepts are sent here, the
// iPhone makes a reminder for each, and the review site reads back which ones
// were checked off so the next review can score them.
//
// The review site authenticates with its own token (COMMITMENTS_TOKEN_SHA256),
// bound to one account (COMMITMENTS_EMAIL). That token works on
// /api/commitments only, and a signed-in user's token does not work there.

export const MAX_COMMITMENTS = 9;
const MAX_TEXT = 200;
const ITEM_ID = /^c[1-9]$/;
const DAY_MS = 24 * 60 * 60_000;
// The iPhone keeps following a week's reminders this long after its Monday.
export const FOLLOW_DAYS = 28;

export class CommitmentError extends Error {}

/** True when the Authorization header carries the token whose SHA-256 is `expectedSha256`. */
export function serviceTokenMatches(expectedSha256, header) {
  if (!/^[0-9a-f]{64}$/.test(expectedSha256 || "")) return false;
  const match = /^Bearer (\S{20,256})$/.exec(header || "");
  if (!match) return false;
  const actual = crypto.createHash("sha256").update(match[1]).digest();
  return crypto.timingSafeEqual(actual, Buffer.from(expectedSha256, "hex"));
}

/** A week is named by its Monday, as a plain date. */
export function validWeek(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value && date.getUTCDay() === 1;
}

export function addDays(day, days) {
  return new Date(Date.parse(`${day}T00:00:00Z`) + days * DAY_MS).toISOString().slice(0, 10);
}

/** The earliest week the iPhone still follows. */
export function followSince(now) {
  return new Date(now.getTime() - FOLLOW_DAYS * DAY_MS).toISOString().slice(0, 10);
}

// One line of plain text: no control characters or line breaks.
function line(value, name, { required }) {
  if (value === undefined || value === null || value === "") {
    if (required) throw new CommitmentError(`${name} is required`);
    return null;
  }
  if (typeof value !== "string") throw new CommitmentError(`${name} must be text`);
  // eslint-disable-next-line no-control-regex
  const clean = value.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  if (!clean) {
    if (required) throw new CommitmentError(`${name} is required`);
    return null;
  }
  if (clean.length > MAX_TEXT) throw new CommitmentError(`${name} is over ${MAX_TEXT} characters`);
  return clean;
}

/** The accepted commitments for one week, as the review site sends them. */
export function validateCommitments(body) {
  const items = body?.items;
  if (!Array.isArray(items) || items.length > MAX_COMMITMENTS) {
    throw new CommitmentError(`items must be a list of at most ${MAX_COMMITMENTS}`);
  }
  const seen = new Set();
  return items.map((item, index) => {
    const at = `items[${index}]`;
    if (!item || typeof item !== "object") throw new CommitmentError(`${at} must be an object`);
    if (typeof item.id !== "string" || !ITEM_ID.test(item.id)) throw new CommitmentError(`${at}.id must be c1-c9`);
    if (seen.has(item.id)) throw new CommitmentError(`${at}.id ${item.id} is repeated`);
    seen.add(item.id);
    const area = item.area === undefined || item.area === null ? "other" : item.area;
    if (typeof area !== "string" || !/^[a-z]{1,20}$/.test(area)) throw new CommitmentError(`${at}.area must be a short lowercase word`);
    return {
      id: item.id,
      text: line(item.text, `${at}.text`, { required: true }),
      measure: line(item.measure, `${at}.measure`, { required: false }),
      area
    };
  });
}

/** What the iPhone reports: the reminder it made (null once removed) and its state. */
export function validateReports(body) {
  const items = body?.items;
  if (!Array.isArray(items) || items.length > 100) throw new CommitmentError("items must be a list of at most 100");
  return items.map((item, index) => {
    const at = `items[${index}]`;
    if (!item || typeof item !== "object") throw new CommitmentError(`${at} must be an object`);
    if (!validWeek(item.week)) throw new CommitmentError(`${at}.week must be a Monday (YYYY-MM-DD)`);
    if (typeof item.id !== "string" || !ITEM_ID.test(item.id)) throw new CommitmentError(`${at}.id must be c1-c9`);
    const reminderId = item.reminderId ?? null;
    if (reminderId !== null && (typeof reminderId !== "string" || !reminderId || reminderId.length > 255)) {
      throw new CommitmentError(`${at}.reminderId must be a reminder id or null`);
    }
    const done = item.done === true;
    let completedAt = null;
    if (done && item.completedAt !== undefined && item.completedAt !== null) {
      const date = typeof item.completedAt === "string" ? new Date(item.completedAt) : new Date(NaN);
      if (Number.isNaN(date.getTime())) throw new CommitmentError(`${at}.completedAt must be a date`);
      completedAt = date.toISOString();
    }
    return { week: item.week, id: item.id, reminderId, done, completedAt };
  });
}

/** A week's state for the review site: no reminder ids, they mean nothing there. */
export function forReviewSite(week, rows) {
  return {
    week,
    items: rows.map((c) => ({
      id: c.id, active: c.active, reminder: Boolean(c.reminderId), done: c.done, completedAt: c.completedAt
    }))
  };
}

/** A commitment as the iPhone needs it: what to write, and when the week ends. */
export function forPhone(c) {
  return {
    week: c.week, id: c.id, text: c.text, measure: c.measure, area: c.area, active: c.active,
    reminderId: c.reminderId, done: c.done, due: addDays(c.week, 6)
  };
}
