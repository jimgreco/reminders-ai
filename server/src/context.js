// When and where the person is, in words a model can plan around: the weekday
// matters (offices and phone lines keep hours) and so does the place (an
// errand at the other house cannot be run from here).

/** "Saturday, November 21, 2026 at 10:15 AM (time zone America/New_York)", or the bare timestamp when the zone is unknown. */
export function describeNow(now, timeZone) {
  const date = new Date(now || Date.now());
  const stamp = now || date.toISOString();
  if (Number.isNaN(date.getTime()) || !timeZone) return `${stamp}${timeZone ? ` (time zone ${timeZone})` : ""}`;
  try {
    const local = new Intl.DateTimeFormat("en-US", { dateStyle: "full", timeStyle: "short", timeZone }).format(date);
    return `${local} (time zone ${timeZone})`;
  } catch {
    // Not a zone this runtime knows.
    return `${stamp} (time zone ${timeZone})`;
  }
}

/** A place name from the phone ("East Hampton, NY"), flattened to one short line. */
export function cleanLocation(value) {
  return typeof value === "string" ? value.replace(/\s+/g, " ").trim().slice(0, 120) : "";
}
