import { describe, expect, it } from 'vitest';
import { formatRunTime } from '../runTime';

const at = (text: string) => new Date(text).getTime() / 1000;

describe('the time of a run', () => {
  const now = new Date('2026-10-23T18:30:00');

  it('is the time alone today', () => {
    expect(formatRunTime(at('2026-10-23T18:02:40'), now)).toBe('18:02');
    expect(formatRunTime(at('2026-10-23T00:05:00'), now)).toBe('00:05');
  });

  it('says yesterday for yesterday, and the date before that', () => {
    expect(formatRunTime(at('2026-10-22T23:59:00'), now)).toBe(
      'yesterday 23:59',
    );
    expect(formatRunTime(at('2026-10-21T09:07:00'), now)).toBe('21.10 09:07');
  });

  it('gives the date when the router clock runs ahead', () => {
    expect(formatRunTime(at('2026-10-25T10:00:00'), now)).toBe('25.10 10:00');
  });
});
