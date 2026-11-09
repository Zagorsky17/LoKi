/** One turn of the loader, shared by the CSS keyframes and the phase below. */
export const SPIN_PERIOD_MS = 1000;

/**
 * A rebuilt spinner would restart its turn; a negative delay taken from the document clock gives
 * every spinner the same phase, so a replacement appears where its predecessor was.
 */
export function spinPhaseDelayMs(now: number): number {
  return -(now % SPIN_PERIOD_MS);
}

/** The declaration to put on a spinner, read off the document clock. */
export function spinPhaseStyle(): string {
  const timelineTime = document.timeline?.currentTime;
  const now =
    typeof timelineTime === 'number' ? timelineTime : performance.now();

  return `animation-delay: ${spinPhaseDelayMs(now)}ms`;
}
