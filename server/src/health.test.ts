import { describe, expect, it } from "vitest";
import { sweeperHealth } from "./health.js";

/**
 * The health check exists to make a dead sweeper visible. These tests assert
 * it actually goes red — a health check that cannot report unhealthy is worse
 * than none, because it converts "deadlines stopped being enforced" into a
 * green light.
 */
describe("sweeper health", () => {
  const staleAfter = 90_000;

  it("is unhealthy before the first sweep", () => {
    // Never started is not the same as fine. A service that boots, fails to
    // start its sweeper, and reports ok would pin every question forever.
    expect(sweeperHealth(null, Date.now(), staleAfter).healthy).toBe(false);
  });

  it("is healthy right after a sweep", () => {
    const now = Date.now();
    expect(sweeperHealth(now, now, staleAfter).healthy).toBe(true);
  });

  it("is healthy while sweeps keep landing", () => {
    const now = Date.now();
    expect(sweeperHealth(now - staleAfter + 1_000, now, staleAfter).healthy).toBe(true);
  });

  it("goes unhealthy once sweeps stop", () => {
    const now = Date.now();
    expect(sweeperHealth(now - staleAfter - 1, now, staleAfter).healthy).toBe(false);
  });

  it("reports 503 when unhealthy and 200 when healthy", () => {
    const now = Date.now();
    expect(sweeperHealth(null, now, staleAfter).status).toBe(503);
    expect(sweeperHealth(now, now, staleAfter).status).toBe(200);
  });
});
