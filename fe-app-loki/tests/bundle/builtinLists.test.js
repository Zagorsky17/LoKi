import { beforeEach, describe, expect, it } from 'vitest';

import { createHarness } from '../lib/luciForm.js';

let harness;

beforeEach(() => {
  harness = createHarness();
});

async function builtinListsOption() {
  harness.uci.add('loki', 'section', 'section_probe');
  Object.assign(harness.store.get('section_probe'), {
    action: 'connection',
    enabled: '1',
    label: 'Probe',
    community_lists: ['ru_only'],
  });
  const map = new harness.form.Map('loki');
  const grid = map.section(harness.form.GridSection, 'section');
  harness.bundle.createSectionContent(grid);
  grid.cfgsections = () => ['section_probe'];
  await grid.load();
  return grid.children.find((child) => child.option === 'community_lists');
}

describe('the built-in lists field', () => {
  it('offers the lists by name in their order, the blocked ones first', async () => {
    const option = await builtinListsOption();

    expect(option.keylist.slice(0, 6)).toEqual([
      'ru_blocked_all',
      'ru_blocked_rkn',
      'ru_blocked_geo',
      'ru_only',
      'ua_blocked',
      'ai',
    ]);
    expect(option.keylist.at(-1)).toBe('ads');
    expect(option.vallist.slice(0, 4)).toEqual([
      'RU Blocked (All)',
      'RU Blocked (RKN)',
      'RU Blocked (Geo)',
      'RU Only',
    ]);
  });
});
