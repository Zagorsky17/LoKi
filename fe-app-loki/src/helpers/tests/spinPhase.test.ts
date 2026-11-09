import { describe, expect, it } from 'vitest';

import { SPIN_PERIOD_MS, spinPhaseDelayMs, spinPhaseStyle } from '../spinPhase';

const globals = globalThis as unknown as {
  document?: { timeline?: { currentTime: unknown } };
};

function withTimelineTime<T>(currentTime: unknown, run: () => T): T {
  const previous = globals.document;
  globals.document = { timeline: { currentTime } };

  try {
    return run();
  } finally {
    globals.document = previous;
  }
}

describe('the phase a spinner is built at', () => {
  it.each([
    [0, 1],
    [4, 1004],
    [123.4, 8765.4],
    [999.9, 41999.9],
    [16.7, 3600016.7],
  ])('is the same at %s and %s ms', (earlier, later) => {
    const atEarlier = earlier + spinPhaseDelayMs(earlier);
    const atLater = later + spinPhaseDelayMs(later);

    expect((atLater - atEarlier) % SPIN_PERIOD_MS).toBe(0);
  });

  it('never delays the start of the turn', () => {
    for (const now of [0, 1, 250, 999, 1000, 12345.6]) {
      expect(spinPhaseDelayMs(now)).toBeLessThanOrEqual(0);
      expect(spinPhaseDelayMs(now)).toBeGreaterThan(-SPIN_PERIOD_MS);
    }
  });
});

describe('the declaration put on a spinner', () => {
  it('is read off the document clock', () => {
    expect(withTimelineTime(2750, spinPhaseStyle)).toBe(
      'animation-delay: -750ms',
    );
  });

  it.each([[null], [undefined], [{ value: 2750, unit: 'ms' }]])(
    'falls back to performance.now() when the clock reads %s',
    (currentTime) => {
      const style = withTimelineTime(currentTime, spinPhaseStyle);
      const delay = Number(/-?[\d.]+/.exec(style)?.[0]);

      expect(delay).toBeLessThanOrEqual(0);
      expect(delay).toBeGreaterThan(-SPIN_PERIOD_MS);
    },
  );
});
