import { beforeEach, describe, expect, it, vi } from 'vitest';

const adopted: Array<[string, string]> = [];
vi.mock('../listItems', () => ({
  findDynamicListItemByValue: (node: { items: string[] }, value: string) =>
    node.items.includes(value) ? { value } : null,
  setDynamicListItemValue: (item: { value: string }, value: string) => {
    adopted.push([item.value, value]);
  },
}));

import { installUciStub } from '../../../helpers/tests/luciStubs';
import {
  adoptMaterializedChildItems,
  cleanupRemovedChildItems,
  getChildItemIds,
  materializeChildItems,
} from '../childItems';

const LEVEL_OPTIONS = {
  typeName: 'fallback_level',
  ownerOption: 'group',
  valueOption: 'name',
  defaults: { server_filter_mode: 'include' },
};

let uci: ReturnType<typeof installUciStub>;

beforeEach(() => {
  adopted.length = 0;
  uci = installUciStub({
    grp: { '.type': 'fallback_group', section: 'vpn' },
    lvl_old: {
      '.type': 'fallback_level',
      group: 'grp',
      name: 'Group #1',
      order: '0',
      server_filter_mode: 'exclude',
      exclude_regex: 'stale',
    },
  });
});

function materializeLevels(
  values: string[],
  staged?: Record<string, Record<string, unknown>>,
) {
  return materializeChildItems(
    'grp',
    {
      ...LEVEL_OPTIONS,
      stagedSettings: (value: unknown) =>
        staged ? staged[`${value}`] || null : null,
    },
    values,
  );
}

describe('a list value that repeats a stored name', () => {
  it('becomes a new item rather than resurrecting the old one', () => {
    const result = materializeLevels(['Group #1'], {
      'Group #1': {
        name: 'Group #1',
        server_filter_mode: 'include',
        include_regex: 'fresh',
      },
    });

    expect(result.itemIds).not.toContain('lvl_old');
    expect(result.itemIds).toHaveLength(1);
    expect([...result.resolved]).toEqual([['Group #1', result.itemIds[0]]]);
    expect(uci.get('loki', result.itemIds[0])).toEqual({
      '.name': result.itemIds[0],
      '.type': 'fallback_level',
      group: 'grp',
      name: 'Group #1',
      server_filter_mode: 'include',
      include_regex: 'fresh',
    });
  });

  it('leaves the item it replaced to the cleanup', () => {
    const result = materializeLevels(['Group #1'], {
      'Group #1': { name: 'Group #1' },
    });

    cleanupRemovedChildItems('grp', 'fallback_level', result.itemIds, 'group');

    expect(getChildItemIds('grp', 'fallback_level', 'group')).toEqual(
      result.itemIds,
    );
  });
});

describe('a list value that is a stored section id', () => {
  it('keeps that item untouched', () => {
    const result = materializeLevels(['lvl_old'], {
      lvl_old: { include_regex: 'must not apply' },
    });

    expect(result.itemIds).toEqual(['lvl_old']);
    expect([...result.resolved]).toEqual([['lvl_old', 'lvl_old']]);
    expect(uci.get('loki', 'lvl_old', 'exclude_regex')).toBe('stale');
    expect(uci.get('loki', 'lvl_old', 'include_regex')).toBe(null);
  });
});

describe('repeated draft values', () => {
  it('collapse into a single new item, staged once', () => {
    const stagedCalls: string[] = [];
    const result = materializeChildItems(
      'grp',
      {
        ...LEVEL_OPTIONS,
        stagedSettings: (value: unknown) => {
          stagedCalls.push(`${value}`);
          return { name: `${value}` };
        },
      },
      ['Group #2', 'Group #2'],
    );

    expect(result.itemIds).toHaveLength(1);
    expect(stagedCalls).toEqual(['Group #2']);
  });
});

describe('writing the same widget twice', () => {
  it('updates the item stored first instead of adding another', () => {
    const first = materializeLevels(['Group #3'], {
      'Group #3': { name: 'Group #3', include_regex: 'fresh' },
    });
    const itemId = first.itemIds[0];
    const listNode = { items: ['Group #3'] };

    adoptMaterializedChildItems(
      { getUIElement: () => ({ node: listNode }) } as unknown as CBIOption,
      'settings',
      first.resolved,
    );
    expect(adopted).toEqual([['Group #3', itemId]]);

    const second = materializeLevels([itemId], {});

    expect(second.itemIds).toEqual([itemId]);
    expect(uci.get('loki', itemId, 'include_regex')).toBe('fresh');
  });

  it('survives a widget that is not mounted', () => {
    const result = materializeLevels(['Group #4'], {
      'Group #4': { name: 'Group #4' },
    });

    expect(() =>
      adoptMaterializedChildItems(
        {
          getUIElement: () => {
            throw new Error('not rendered');
          },
        } as unknown as CBIOption,
        'settings',
        result.resolved,
      ),
    ).not.toThrow();
  });
});
