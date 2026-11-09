import { describe, expect, it, vi } from 'vitest';

vi.stubGlobal('_', (text: string) => text);

const { validateRegex } = await import('../validators');

describe('validateRegex', () => {
  it('accepts the RE2 a server filter is written in', () => {
    for (const pattern of [
      '^DE\\d$',
      '(?i)^de|nl',
      '(?:DE|NL)\\d+',
      '(?P<country>DE)\\s\\w',
      'a+?b',
      '',
    ])
      expect(validateRegex(pattern)).toBe(true);
  });

  it('refuses what no engine can compile', () => {
    for (const pattern of ['(', '[DE', 'a**'])
      expect(validateRegex(pattern)).toBe('Invalid regular expression');
  });
});
