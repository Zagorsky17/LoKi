import { describe, expect, it } from 'vitest';
import { formatDuration } from '../formatDuration';

describe('a duration', () => {
  it('is given in its two largest units', () => {
    expect(
      [40, 600, 8100, 7200, 270000].map((value) => formatDuration(value)),
    ).toEqual(['40 s', '10 min', '2 h 15 min', '2 h', '3 d 3 h']);
  });
});
