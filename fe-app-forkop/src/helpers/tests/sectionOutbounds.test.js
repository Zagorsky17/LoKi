import { describe, expect, it } from 'vitest';

import { installUciStub } from './luciStubs';
import { missingConnectionOutbound } from '../../forkop/tabs/sections/references';
import { missingFilterSelectionMessage } from '../../forkop/tabs/sections/serverFilters';

function load() {
  installUciStub();
  return { missingConnectionOutbound, missingFilterSelectionMessage };
}

function modalMap(values) {
  return {
    section: 'section_main',
    lookupOption(name, section_id) {
      return Object.prototype.hasOwnProperty.call(values, name)
        ? [{ formvalue: () => values[name] }, section_id || this.section]
        : null;
    },
  };
}

const OUTBOUND_SOURCES = {
  connection_link: ['link_a1b2c3'],
  subscription_url: ['sub_a1b2c3'],
  interfaces: ['awg0'],
  outbound_jsons: ['{"type":"socks","tag":"Local"}'],
};

describe('connection section outbounds', () => {
  it('refuses a section that names no outbound at all', () => {
    const { missingConnectionOutbound } = load();
    const map = modalMap({ action: 'connection' });

    expect(missingConnectionOutbound(map, map.section)).toBe(true);
  });

  it('accepts a section that names any single source', () => {
    const { missingConnectionOutbound } = load();

    for (const [option, value] of Object.entries(OUTBOUND_SOURCES)) {
      const map = modalMap({ action: 'connection', [option]: value });
      expect(missingConnectionOutbound(map, map.section)).toBe(false);
    }
  });

  it('does not count a URLTest or a Fallback as a source', () => {
    const { missingConnectionOutbound } = load();
    const map = modalMap({
      action: 'connection',
      tunnels: ['retired'],
      urltest: ['urltest_a1b2c3'],
      fallback_group: ['group_a1b2c3'],
    });

    expect(missingConnectionOutbound(map, map.section)).toBe(true);
  });

  it('treats a list of blank items as no source', () => {
    const { missingConnectionOutbound } = load();
    const map = modalMap({
      action: 'connection',
      connection_link: ['', ' '],
    });

    expect(missingConnectionOutbound(map, map.section)).toBe(true);
  });

  it('leaves every other action alone', () => {
    const { missingConnectionOutbound } = load();

    for (const action of ['dns', 'block', 'bypass']) {
      const map = modalMap({ action });
      expect(missingConnectionOutbound(map, map.section)).toBe(false);
    }
  });
});

describe('server filter selection', () => {
  function filterMode(mode, values = {}) {
    return { formvalue: () => mode, map: modalMap(values) };
  }

  it('refuses "only selected" without a single selection', () => {
    const { missingFilterSelectionMessage } = load();

    expect(
      missingFilterSelectionMessage(
        filterMode('include', {
          include_outbounds: [],
          include_regex: '',
        }),
        'settings',
      ),
    ).toBe('Select a server or set a pattern');
  });

  it('accepts a selection made by name, by pattern or by group', () => {
    const { missingFilterSelectionMessage } = load();
    const selections = [
      { include_outbounds: ['Germany'] },
      { include_regex: 'Germany|Finland' },
      { include_groups: ['Fastest'] },
    ];

    for (const selection of selections) {
      expect(
        missingFilterSelectionMessage(
          filterMode('include', selection),
          'settings',
        ),
      ).toBeNull();
    }
  });

  it('leaves the other filter modes alone', () => {
    const { missingFilterSelectionMessage } = load();

    for (const mode of ['all', 'exclude', 'direct']) {
      expect(
        missingFilterSelectionMessage(filterMode(mode, {}), 'settings'),
      ).toBeNull();
    }
  });
});
