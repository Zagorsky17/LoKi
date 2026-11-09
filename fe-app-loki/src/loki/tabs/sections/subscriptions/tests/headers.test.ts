import { describe, expect, it } from 'vitest';

import {
  nextSubscriptionHeaderRowId,
  subscriptionHeaderLines,
  subscriptionHeaderRows,
  syncSubscriptionHeaderRows,
} from '../headers';

describe('subscriptionHeaderRows', () => {
  it('turns each line into a row, empty values included', () => {
    expect(
      subscriptionHeaderRows(['Authorization: Bearer token', 'X-Empty:']),
    ).toEqual([
      {
        '.name': 'header_0',
        '.type': 'header',
        name: 'Authorization',
        value: 'Bearer token',
      },
      { '.name': 'header_1', '.type': 'header', name: 'X-Empty', value: '' },
    ]);
  });
});

describe('subscriptionHeaderLines', () => {
  it('writes a value back with one space, and none when it is empty', () => {
    const map = {
      config: 'json',
      data: {
        sections: () => [
          { name: 'Authorization', value: 'Bearer token' },
          { name: 'X-Empty' },
        ],
      },
    };

    expect(subscriptionHeaderLines(map as unknown as CBIMap)).toEqual([
      'Authorization: Bearer token',
      'X-Empty:',
    ]);
  });
});

describe('syncSubscriptionHeaderRows', () => {
  it('keeps what the visible fields hold before the grid reloads', () => {
    const stored: Record<string, Record<string, unknown>> = {
      header_0: { name: 'Old', value: 'old' },
      header_1: { name: '', value: '' },
    };
    const section = {
      map: {
        config: 'json',
        data: {
          get: (_config: string, sectionId: string) =>
            stored[sectionId] ?? null,
          set: (
            _config: string,
            sectionId: string,
            option: string,
            value: unknown,
          ) => {
            stored[sectionId][option] = value;
          },
          unset: (_config: string, sectionId: string, option: string) => {
            delete stored[sectionId][option];
          },
        },
      },
      cfgsections: () => ['header_0', 'header_1'],
      children: [
        {
          editable: true,
          option: 'name',
          formvalue: (sectionId: string) =>
            sectionId === 'header_0' ? 'Changed' : '',
        },
        {
          editable: true,
          option: 'value',
          formvalue: (sectionId: string) =>
            sectionId === 'header_0' ? 'current' : '',
        },
      ],
      nextHeaderRowIndex: 2,
    };

    syncSubscriptionHeaderRows(section as unknown as CBISection);

    expect(stored.header_0).toEqual({ name: 'Changed', value: 'current' });
    expect(stored.header_1).toEqual({ name: '', value: '' });
  });
});

describe('nextSubscriptionHeaderRowId', () => {
  it('skips an id the grid already holds', () => {
    const stored: Record<string, Record<string, unknown>> = {};
    const section = {
      map: {
        config: 'json',
        data: {
          get: (_config: string, sectionId: string) =>
            stored[sectionId] ?? null,
        },
      },
      nextHeaderRowIndex: 2,
    } as unknown as CBISection;

    expect(nextSubscriptionHeaderRowId(section)).toBe('header_2');
    stored.header_2 = {};
    expect(nextSubscriptionHeaderRowId(section)).toBe('header_3');
    delete stored.header_2;
    expect(nextSubscriptionHeaderRowId(section)).toBe('header_4');
  });
});
