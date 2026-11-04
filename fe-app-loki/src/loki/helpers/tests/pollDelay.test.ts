import { describe, expect, it } from 'vitest';
import { pollDelayForDuration } from '../pollDelay';

describe('pollDelayForDuration', () => {
  it('keeps the requested interval while the answers are cheap', () => {
    expect(pollDelayForDuration(1500, 12, 15000)).toBe(1500);
    expect(pollDelayForDuration(1500, 180, 15000)).toBe(1500);
  });

  it('spaces the poll out in proportion to what the last answer cost', () => {
    expect(pollDelayForDuration(1500, 400, 15000)).toBe(3200);
    expect(pollDelayForDuration(5000, 1200, 20000)).toBe(9600);
  });

  it('never spaces it out past the ceiling the tab allows', () => {
    expect(pollDelayForDuration(1500, 9000, 15000)).toBe(15000);
  });

  it('falls back to the requested interval without a measurement', () => {
    expect(pollDelayForDuration(1500, 0, 15000)).toBe(1500);
    expect(pollDelayForDuration(1500, Number.NaN, 15000)).toBe(1500);
    expect(pollDelayForDuration(1500, -20, 15000)).toBe(1500);
  });
});
