import { describe, expect, it } from 'vitest';

import {
  DOMAIN_LIST_INCLUDES,
  DOMAIN_LIST_OPTIONS,
} from '../../../../constants';
import { builtinListRefusal } from '../ruleSets';

describe('a built-in list picked beside a regional list that holds it', () => {
  it('is refused when a selected regional list already holds it', () => {
    expect(builtinListRefusal(['ru_blocked_rkn'], 'youtube')).toBe(
      'YouTube is already in RU Blocked (RKN)',
    );
    expect(builtinListRefusal(['ru_only', 'ru_blocked_all'], 'chatgpt')).toBe(
      'ChatGPT is already in RU Blocked (All)',
    );
    expect(builtinListRefusal(['ru_blocked_all'], 'ru_blocked_geo')).toBe(
      'RU Blocked (Geo) is already in RU Blocked (All)',
    );
  });

  it('is refused when it would hold lists already selected, naming them', () => {
    expect(builtinListRefusal(['youtube'], 'ru_blocked_rkn')).toBe(
      'YouTube is already in RU Blocked (RKN): remove it first',
    );
    expect(
      builtinListRefusal(['telegram', 'github', 'discord'], 'ru_blocked_all'),
    ).toBe(
      'Telegram, Discord are already in RU Blocked (All): remove them first',
    );
  });

  it('is taken when no selected list holds it and it holds none of them', () => {
    expect(builtinListRefusal(['ru_blocked_rkn'], 'ru_blocked_geo')).toBeNull();
    expect(builtinListRefusal(['ru_blocked_rkn'], 'chatgpt')).toBeNull();
    expect(builtinListRefusal(['ru_blocked_geo'], 'telegram')).toBeNull();
    expect(builtinListRefusal(['ru_blocked_all'], 'github')).toBeNull();
    expect(builtinListRefusal(['github', 'ai'], 'ru_blocked_all')).toBeNull();
    expect(builtinListRefusal([], 'ru_blocked_all')).toBeNull();
  });

  it('names only lists the page offers', () => {
    const offered = Object.keys(DOMAIN_LIST_OPTIONS);
    Object.entries(DOMAIN_LIST_INCLUDES).forEach(([list, held]) => {
      expect(offered).toContain(list);
      held.forEach((value) => expect(offered).toContain(value));
    });
  });
});
