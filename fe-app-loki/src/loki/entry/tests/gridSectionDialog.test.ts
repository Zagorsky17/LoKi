import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../cbi/childItems', () => ({ nextSectionId: () => 'x' }));
vi.mock('../../cbi/grid', () => ({ getRuleEditButtonText: () => 'Edit' }));

import { configureGridSection } from '../gridSection';

const calls: unknown[][] = [];
let state: {
  values: Record<string, Record<string, Record<string, unknown>>>;
  creates: Record<string, unknown>;
  changes: Record<string, unknown>;
  deletes: Record<string, unknown>;
  reorder: Record<string, boolean>;
};

beforeEach(() => {
  calls.length = 0;
  state = {
    values: { loki: { sec: { '.name': 'sec', '.index': 0 } } },
    creates: {},
    changes: {},
    deletes: {},
    reorder: {},
  };
  const globals = globalThis as unknown as Record<string, unknown>;
  globals.uci = { state, get: () => null };
  globals.form = {
    GridSection: {
      prototype: {
        renderMoreOptionsModal(sectionId: string) {
          calls.push(['open', sectionId]);
          return Promise.resolve();
        },
        handleModalCancel(_map: unknown, _ev: Event, isSaving: boolean) {
          calls.push(['close', isSaving]);
          return Promise.resolve();
        },
      },
    },
  };
});

function grid(map: object = {}) {
  const sectionRef = {
    map,
    titleFn: () => '',
    sectiontype: 'section',
    getPreviousModalMap: () => null,
  } as unknown as CBISection;
  configureGridSection(sectionRef, 'section', 'Section', 'Add');
  return sectionRef as CBISection & {
    handleAdd: () => Promise<void>;
    handleModalCancel: (map: unknown, ev: Event, isSaving?: boolean) => unknown;
  };
}

function mapData() {
  const sections: Record<string, Record<string, unknown>> = {};
  return {
    sections,
    data: {
      sections: (_config: string, type: string) =>
        Object.values(sections).filter((section) => section['.type'] === type),
      add: (_config: string, type: string, name: string) => {
        sections[name] = { '.type': type, '.name': name };
        return name;
      },
      set: (_config: string, id: string, option: string, value: unknown) => {
        sections[id][option] = value;
      },
      remove: (_config: string, id: string) => {
        delete sections[id];
      },
    },
  };
}

function opening(result: Promise<void>) {
  const prototype = (
    globalThis as unknown as {
      form: { GridSection: { prototype: Record<string, unknown> } };
    }
  ).form.GridSection.prototype;
  prototype.renderMoreOptionsModal = () => result;
}

function nestedDialogWrites() {
  state.creates.loki = { tun_1: { '.type': 'tunnel', section: 'sec' } };
  state.changes.loki = { sec: { tunnels: ['tun_1'] } };
}

describe('a section dialog', () => {
  it('takes back what its nested dialogs wrote when it is dismissed', async () => {
    const sectionRef = grid();
    await sectionRef.renderMoreOptionsModal('sec');
    nestedDialogWrites();

    await sectionRef.handleModalCancel({}, {} as Event, false);

    expect(state.creates.loki).toBeUndefined();
    expect(state.changes.loki).toBeUndefined();
    expect(calls).toEqual([
      ['open', 'sec'],
      ['close', false],
    ]);
  });

  it('opened by Add holds the new section until it is closed', async () => {
    opening(Promise.resolve());
    const { sections, data } = mapData();
    const map = { config: 'loki', data } as { addedSection?: string };

    await grid(map).handleAdd();

    expect(sections).toEqual({
      x: { '.type': 'section', '.name': 'x', label: 'Section #1' },
    });
    expect(map.addedSection).toBe('x');
  });

  it('that fails to open takes the section Add created back', async () => {
    const failure = new Error('XHR request timed out');
    opening(Promise.reject(failure));
    const { sections, data } = mapData();
    const map = { config: 'loki', data } as { addedSection?: string };

    await expect(grid(map).handleAdd()).rejects.toBe(failure);

    expect(sections).toEqual({});
    expect(map.addedSection).toBeUndefined();
  });

  it('keeps them when it closes by saving', async () => {
    const sectionRef = grid();
    await sectionRef.renderMoreOptionsModal('sec');
    nestedDialogWrites();

    await sectionRef.handleModalCancel({}, {} as Event, true);

    expect(state.creates.loki).toEqual({
      tun_1: { '.type': 'tunnel', section: 'sec' },
    });
    expect(calls).toEqual([
      ['open', 'sec'],
      ['close', true],
    ]);
  });
});
