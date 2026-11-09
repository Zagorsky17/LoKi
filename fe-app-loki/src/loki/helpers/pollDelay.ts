// The interval a tab asks for is a floor: a poll that cost the router more than a fraction of it
// spaces itself out by what the last answer cost.
const POLL_DUTY_FACTOR = 8;

export function pollDelayForDuration(
  baseIntervalMs: number,
  durationMs: number,
  maxIntervalMs: number,
) {
  if (!Number.isFinite(durationMs) || durationMs <= 0) {
    return baseIntervalMs;
  }

  return Math.min(
    Math.max(baseIntervalMs, Math.round(durationMs * POLL_DUTY_FACTOR)),
    maxIntervalMs,
  );
}
