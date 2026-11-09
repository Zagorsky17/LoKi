import { beforeEach, describe, expect, it, vi } from 'vitest';

const cleanupCalls: unknown[][] = [];
let outboundMissing = false;
let matcherMissing = false;
let missingLookup: unknown[] = [];
const saves: unknown[][] = [];
const refusals: unknown[] = [];
const saveResult = Promise.resolve(true);
const dialogCalls: string[] = [];

vi.mock('../../../cbi/childItems', () => ({
  cleanupRemovedChildItems: (...args: unknown[]) => {
    cleanupCalls.push(
      args.map((arg) => (typeof arg === 'function' ? arg.name : arg)),
    );
  },
}));
vi.mock('../../../cbi/grid', () => ({ loadVisibleTableOptions: () => {} }));
vi.mock('../fallback', () => ({ removeFallbackLevels() {} }));
vi.mock('../subscriptions/model', () => ({
  loadDefaultSubscriptionHeaders: () => Promise.resolve(),
}));
vi.mock('../../../cbi/modal', () => ({
  saveSectionModal: (...args: unknown[]) => {
    saves.push(args);
    return saveResult;
  },
  reportRefusedSave: (error: unknown) => {
    refusals.push(error);
  },
}));
vi.mock('../outboundNames', () => ({
  forgetOutboundNameChoices: () => {
    dialogCalls.push('forget server names');
  },
}));
vi.mock('../references', () => ({
  missingConnectionOutbound: (...args: unknown[]) => {
    missingLookup = args;
    return outboundMissing;
  },
  missingDnsMatcher: () => matcherMissing,
}));

import { configureSectionSection } from '../table';

const removeCalls: Array<{ args: unknown[]; self: unknown }> = [];
const removeResult = {};

beforeEach(() => {
  cleanupCalls.length = 0;
  removeCalls.length = 0;
  saves.length = 0;
  refusals.length = 0;
  dialogCalls.length = 0;
  outboundMissing = false;
  matcherMissing = false;
});

function configured() {
  const sectionRef = {
    renderMoreOptionsModal(sectionId: string) {
      dialogCalls.push(`open ${sectionId}`);
      return Promise.resolve();
    },
    handleRemove(...args: unknown[]) {
      removeCalls.push({ args, self: this });
      return removeResult;
    },
  };
  configureSectionSection(sectionRef as unknown as CBISection);
  return sectionRef as unknown as CBISection & {
    handleRemove: (id: string, event: Event) => unknown;
    handleModalSave: (map: unknown, event: Event) => unknown;
  };
}

describe('opening a section dialog', () => {
  it('asks afresh for the server names its subscriptions deliver', async () => {
    const sectionRef = configured();

    await sectionRef.renderMoreOptionsModal('parent');

    expect(dialogCalls).toEqual(['forget server names', 'open parent']);
  });
});

describe('deleting a section', () => {
  it('takes every kind of child with it, in one pass', () => {
    const event = {} as Event;
    const sectionRef = configured();

    expect(sectionRef.handleRemove('parent', event)).toBe(removeResult);
    expect(cleanupCalls).toEqual([
      ['parent', 'connection_link', []],
      ['parent', 'subscription_url', []],
      ['parent', 'section_interface', []],
      ['parent', 'urltest', []],
      ['parent', 'fallback_group', [], undefined, 'removeFallbackLevels'],
    ]);
  });

  it('still calls the grid its own removal', () => {
    const event = {} as Event;
    const sectionRef = configured();
    sectionRef.handleRemove('parent', event);

    expect(removeCalls).toHaveLength(1);
    expect(removeCalls[0].args).toEqual(['parent', event]);
    expect(removeCalls[0].self).toBe(sectionRef);
  });
});

describe('saving a section the runtime graph would drop', () => {
  it('writes nothing and says why', () => {
    const sectionRef = configured();
    const modalMap = { section: 'parent' };
    outboundMissing = true;

    sectionRef.handleModalSave(modalMap, {} as Event);

    expect(missingLookup).toEqual([modalMap, 'parent']);
    expect(saves).toEqual([]);
    expect(refusals).toEqual([
      'Add a connection URI, subscription, interface or JSON outbound',
    ]);
  });

  it('refuses a DNS section with nothing to answer', () => {
    const sectionRef = configured();
    matcherMissing = true;

    sectionRef.handleModalSave({ section: 'parent' }, {} as Event);

    expect(saves).toEqual([]);
    expect(refusals).toEqual([
      'Add a domain, built-in list, rule set or device',
    ]);
  });

  it('saves normally once the outbound is there', () => {
    const sectionRef = configured();
    const modalMap = { section: 'parent' };
    const event = {} as Event;

    expect(sectionRef.handleModalSave(modalMap, event)).toBe(saveResult);
    expect(saves).toEqual([[sectionRef, modalMap, event]]);
    expect(refusals).toEqual([]);
  });
});
