import { describe, expect, it } from 'vitest';

import { syncServerFilterFields } from '../serverFilters';

function sharedField(store: { values: string[] }) {
  return {
    getUIElement() {
      return {
        getValue: () => store.values,
        setValue: (next: string[]) => {
          store.values = next;
        },
      };
    },
  };
}

describe('syncServerFilterFields', () => {
  it('copies the visible mode value into the hidden one', () => {
    const include = { values: ['Alpha'] };
    const exclude = { values: [] as string[] };

    syncServerFilterFields(
      {
        include: { exclude_outbounds: sharedField(include) },
        exclude: { exclude_outbounds: sharedField(exclude) },
      } as unknown as Parameters<typeof syncServerFilterFields>[0],
      'include',
      'settings',
    );

    expect(exclude.values).toEqual(['Alpha']);
  });

  it('does nothing for a mode that has no fields', () => {
    const include = { values: ['Alpha'] };

    expect(() =>
      syncServerFilterFields(
        {
          include: { exclude_outbounds: sharedField(include) },
        } as unknown as Parameters<typeof syncServerFilterFields>[0],
        'exclude',
        'settings',
      ),
    ).not.toThrow();
    expect(include.values).toEqual(['Alpha']);
  });
});
