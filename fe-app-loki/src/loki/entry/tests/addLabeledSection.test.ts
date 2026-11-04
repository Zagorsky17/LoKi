import { describe, expect, it, vi } from 'vitest';

vi.mock('../../cbi/childItems', () => ({
  nextSectionId: (typeName: string) => `${typeName}_a1b2c3`,
}));

import { addLabeledSection } from '../gridSection';

function grid(
  sectiontype: string,
  stored: Record<string, { type: string; label?: string }>,
) {
  const written: { requestedId?: string; label?: unknown } = {};
  const sectionRef = {
    sectiontype,
    map: {
      config: 'loki',
      data: {
        sections: (_config: string, type: string) =>
          Object.entries(stored)
            .filter(([, section]) => section.type === type)
            .map(([name, section]) => ({ '.name': name, ...section })),
        add: (_config: string, _type: string, sectionId: string) => {
          written.requestedId = sectionId;
          return 'cfg-new';
        },
        set: (
          _config: string,
          _sectionId: string,
          _option: string,
          value: unknown,
        ) => {
          written.label = value;
        },
      },
    },
  };
  return { sectionRef: sectionRef as unknown as CBISection, written };
}

describe.each([
  ['section', 'Section #3'],
  ['server', 'Server #3'],
])('adding a %s row', (sectiontype, expectedLabel) => {
  it('creates it under an id naming its type, labelled for the user', () => {
    const prefix = sectiontype === 'section' ? 'Section' : 'Server';
    const { sectionRef, written } = grid(sectiontype, {
      one: { type: sectiontype, label: `${prefix} #1` },
      two: { type: sectiontype, label: `${prefix} #2` },
    });

    expect(addLabeledSection(sectionRef)).toBe('cfg-new');
    expect(written.requestedId).toBe(`${sectiontype}_a1b2c3`);
    expect(written.label).toBe(expectedLabel);
  });
});

describe('the number of a new row', () => {
  it('is one past the highest one taken, not one past the count', () => {
    const { sectionRef, written } = grid('server', {
      a: { type: 'server', label: 'Server #1' },
      b: { type: 'server', label: 'Server #2' },
      c: { type: 'server', label: 'Server #3' },
      d: { type: 'server', label: 'Server #5' },
      e: { type: 'server', label: 'Server #6' },
    });

    addLabeledSection(sectionRef);
    expect(written.label).toBe('Server #7');
  });

  it('skips a name a row of the other grid has, since names are shared', () => {
    const { sectionRef, written } = grid('server', {
      a: { type: 'server', label: 'Server #1' },
      b: { type: 'section', label: 'Server #2' },
    });

    addLabeledSection(sectionRef);
    expect(written.label).toBe('Server #3');
  });

  it('starts at one among rows the user named', () => {
    const { sectionRef, written } = grid('section', {
      a: { type: 'section', label: 'Proxy' },
      b: { type: 'section', label: 'Block' },
    });

    addLabeledSection(sectionRef);
    expect(written.label).toBe('Section #1');
  });
});
