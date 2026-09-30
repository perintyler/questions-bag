import { describe, expect, it } from "vitest";
import { MAX_LIST_LIMIT, parseLimit, parseSince, toSurface } from "./params.js";

describe("surfaces", () => {
  it("accepts supervisor answering on the user's behalf", () => {
    expect(toSurface("supervisor")).toBe("supervisor");
  });

  it("still accepts this bag's own surfaces and nothing else", () => {
    for (const surface of ["notification", "app", "web", "cli", "ios"]) {
      expect(toSurface(surface)).toBe(surface);
    }
    expect(toSurface("slack")).toBeNull();
    expect(toSurface(undefined)).toBeNull();
  });
});

describe("?limit=", () => {
  it("leaves the store's default when absent", () => {
    expect(parseLimit(undefined)).toEqual({ ok: true, value: undefined });
  });

  it("takes a whole number up to the cap", () => {
    expect(parseLimit("1")).toEqual({ ok: true, value: 1 });
    expect(parseLimit(String(MAX_LIST_LIMIT))).toEqual({ ok: true, value: MAX_LIST_LIMIT });
  });

  it("refuses zero, fractions, words, repeats and anything past the cap", () => {
    for (const raw of ["0", "-1", "2.5", "ten", ["1", "2"], String(MAX_LIST_LIMIT + 1)]) {
      expect(parseLimit(raw).ok).toBe(false);
    }
  });
});

describe("?since=", () => {
  const INSTANT = Date.UTC(2026, 8, 29, 12, 34, 56, 789);

  it("reads epoch milliseconds, dropping the fraction of a second", () => {
    expect(parseSince(String(INSTANT))).toEqual({ ok: true, value: "2026-09-29 12:34:56" });
  });

  it("reads ISO 8601 with a zone", () => {
    expect(parseSince("2026-09-29T12:34:56.789Z")).toEqual({ ok: true, value: "2026-09-29 12:34:56" });
    expect(parseSince("2026-09-29T08:34:56-04:00")).toEqual({ ok: true, value: "2026-09-29 12:34:56" });
  });

  it("reads a time with no zone as UTC, like the timestamps this service hands out", () => {
    // Echoing back a created_at must mean the same instant, not one shifted
    // by the machine's offset.
    expect(parseSince("2026-09-29 12:34:56")).toEqual({ ok: true, value: "2026-09-29 12:34:56" });
    expect(parseSince("2026-09-29T12:34:56")).toEqual({ ok: true, value: "2026-09-29 12:34:56" });
  });

  it("is absent when not given", () => {
    expect(parseSince(undefined)).toEqual({ ok: true, value: undefined });
  });

  it("refuses what is not a time", () => {
    for (const raw of ["yesterday", "2026-13-45", ["1", "2"], "99999999999999999"]) {
      expect(parseSince(raw).ok).toBe(false);
    }
  });
});
