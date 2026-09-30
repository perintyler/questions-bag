/**
 * Reading the service's request parameters.
 *
 * Kept out of index.ts, which listens as soon as it is imported, so the rules
 * can be tested without a running service.
 */

import type { Surface } from "../../src/types.js";

export const SURFACES: Surface[] = ["notification", "app", "web", "cli", "ios", "supervisor"];

export function toSurface(value: unknown): Surface | null {
  return typeof value === "string" && (SURFACES as string[]).includes(value)
    ? (value as Surface)
    : null;
}

/** The most rows one `GET /questions` returns, whatever it asks for. */
export const MAX_LIST_LIMIT = 500;

export type Parsed<T> = { ok: true; value: T | undefined } | { ok: false; error: string };

/** `?limit=`: a whole number from 1 to MAX_LIST_LIMIT. Absent means the store's default. */
export function parseLimit(raw: unknown): Parsed<number> {
  if (raw === undefined || raw === "") return { ok: true, value: undefined };
  const n = typeof raw === "string" && /^\d+$/.test(raw) ? Number(raw) : NaN;
  if (!Number.isInteger(n) || n < 1 || n > MAX_LIST_LIMIT) {
    return { ok: false, error: `limit must be a whole number from 1 to ${MAX_LIST_LIMIT}` };
  }
  return { ok: true, value: n };
}

/**
 * `?since=`: epoch milliseconds, or an ISO 8601 time. Returned in the store's
 * own timestamp shape, SQLite's UTC `YYYY-MM-DD HH:MM:SS`.
 *
 * A time with no zone is read as UTC, not local time. That is what every
 * timestamp this service hands out means, so a caller echoing one back gets
 * the instant it was given — where `Date.parse` would shift it by the
 * machine's offset.
 *
 * Milliseconds are dropped rather than rounded up: the store keeps whole
 * seconds, so a row written in the same second as `since` still matches.
 */
export function parseSince(raw: unknown): Parsed<string> {
  if (raw === undefined || raw === "") return { ok: true, value: undefined };
  if (typeof raw !== "string") return { ok: false, error: "since must be given once" };

  let ms: number;
  if (/^\d+$/.test(raw)) {
    ms = Number(raw);
  } else {
    const hasTime = /\d[T ]\d/.test(raw);
    const hasZone = /(Z|[+-]\d{2}:?\d{2})$/i.test(raw);
    ms = Date.parse(hasTime && !hasZone ? `${raw.replace(" ", "T")}Z` : raw);
  }

  const date = new Date(ms);
  if (!Number.isFinite(ms) || Number.isNaN(date.getTime())) {
    return { ok: false, error: "since must be epoch milliseconds or an ISO 8601 time" };
  }
  return { ok: true, value: date.toISOString().slice(0, 19).replace("T", " ") };
}
