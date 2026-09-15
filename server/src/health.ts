/**
 * Whether deadlines are actually being enforced.
 *
 * Pure so it can be tested without a running service — the point of this
 * module is that the unhealthy branch is reachable in a test. A health check
 * whose failing state nothing ever exercises is a claim, not evidence, and
 * this one guards the failure the whole bag exists to prevent: questions
 * piling up pending forever while the service reports a cheerful "ok".
 */
export interface SweeperHealth {
  healthy: boolean;
  status: 200 | 503;
  last_sweep_at: string | null;
  age_ms: number | null;
  stale_after_ms: number;
}

export function sweeperHealth(
  lastSweepAt: number | null,
  now: number,
  staleAfterMs: number,
): SweeperHealth {
  const age = lastSweepAt === null ? null : now - lastSweepAt;
  // Never started and stopped running are both failures, and they are both
  // this branch: either way nothing is closing elapsed questions.
  const healthy = age !== null && age < staleAfterMs;

  return {
    healthy,
    status: healthy ? 200 : 503,
    last_sweep_at: lastSweepAt === null ? null : new Date(lastSweepAt).toISOString(),
    age_ms: age,
    stale_after_ms: staleAfterMs,
  };
}
