import { describe, expect, it } from "vitest";
import { isDirectLoopback, type ForwardableRequest } from "./loopback.js";

/**
 * `/config` hands out BARRY_SECRET, gated on this check. The failure it exists
 * to prevent is not the guard erroring — it is the guard INVERTING: behind a
 * reverse proxy every request presents as loopback, so a socket-only check
 * would serve the secret to the whole tailnet while looking exactly as healthy
 * as it does now.
 */
const req = (
  remoteAddress: string | undefined,
  headers: Record<string, unknown> = {},
): ForwardableRequest => ({ headers, socket: { remoteAddress } });

describe("isDirectLoopback", () => {
  it("accepts a direct loopback caller", () => {
    expect(isDirectLoopback(req("127.0.0.1"))).toBe(true);
    expect(isDirectLoopback(req("::1"))).toBe(true);
    expect(isDirectLoopback(req("::ffff:127.0.0.1"))).toBe(true);
  });

  it("rejects a caller from anywhere else", () => {
    expect(isDirectLoopback(req("100.97.236.110"))).toBe(false);
    expect(isDirectLoopback(req("192.168.1.10"))).toBe(false);
    expect(isDirectLoopback(req(undefined))).toBe(false);
  });

  /**
   * The case that matters. Caddy connects from 127.0.0.1 and sets
   * X-Forwarded-For; without this the vhost would publish the secret.
   */
  it("rejects a proxied request even though the socket is loopback", () => {
    expect(isDirectLoopback(req("127.0.0.1", { "x-forwarded-for": "100.97.236.110" })))
      .toBe(false);
  });

  it("rejects the other forwarding spellings too", () => {
    expect(isDirectLoopback(req("127.0.0.1", { "x-forwarded-host": "questions.barry.lan" })))
      .toBe(false);
    expect(isDirectLoopback(req("127.0.0.1", { forwarded: "for=100.97.236.110" })))
      .toBe(false);
  });

  /**
   * The header is caller-appendable, so its CONTENTS prove nothing — a relayed
   * request can claim to come from 127.0.0.1. Presence alone must be
   * disqualifying, or the guard is trivially bypassed by the party it guards
   * against.
   */
  it("does not trust a forwarded-for that claims to be local", () => {
    expect(isDirectLoopback(req("127.0.0.1", { "x-forwarded-for": "127.0.0.1" })))
      .toBe(false);
  });
});
