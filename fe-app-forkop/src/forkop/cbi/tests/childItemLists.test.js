import { beforeEach, describe, expect, it } from 'vitest';

import {
  createFormSectionStub,
  installLuciStubs,
} from '../../../helpers/tests/luciStubs';
import { createSectionContent } from '../../tabs/sections';
import { childPendingSettingsStore } from '../itemSettings';

const SECTIONS = {
  vpn: { '.type': 'section', label: 'VPN', action: 'connection' },
  sub_stored: {
    '.type': 'subscription_url',
    section: 'vpn',
    url: 'https://example.com/list',
    tag: 'sub1',
  },
  iface_stored: {
    '.type': 'section_interface',
    section: 'vpn',
    name: 'eth1',
    display_name: 'Uplink',
  },
  urltest_stored: { '.type': 'urltest', section: 'vpn', name: 'Fastest' },
  group_stored: { '.type': 'fallback_group', section: 'vpn', name: 'Backup' },
};

function optionNamed(build, name) {
  const section = createFormSectionStub();
  build(section);
  const found = section.options.find((option) => option.name === name);
  expect(found, `no option named ${name}`).toBeTruthy();
  return found;
}

function listOption(name) {
  return optionNamed(createSectionContent, name);
}

function hasDialog(option, owner, value) {
  return option.hasItemSettings(owner, value);
}

const LISTS = [
  ['subscription_url', 'sub_stored', 'https://example.com/list', 'vpn'],
  ['interfaces', 'iface_stored', 'eth1', 'vpn'],
  ['urltest', 'urltest_stored', 'Fastest', 'vpn'],
  ['fallback_group', 'group_stored', 'Backup', 'vpn'],
];

describe('child item lists', () => {
  beforeEach(() => {
    installLuciStubs(SECTIONS);
  });

  it.each(LISTS.filter(([name]) => name !== 'fallback_group'))(
    '%s finds staged settings under what a saved entry shows',
    (name, itemId, shown, owner) => {
      const option = listOption(name);
      childPendingSettingsStore(option, owner)[shown] = { staged: 'yes' };

      expect(option.stagedChildSettings(owner, itemId)).toEqual({
        staged: 'yes',
      });
    },
  );

  it.each(LISTS)(
    '%s offers a dialog for a saved entry',
    (name, itemId, _shown, owner) => {
      expect(hasDialog(listOption(name), owner, itemId)).toBe(true);
    },
  );

  it.each([['urltest', 'vpn']])(
    '%s hands a draft entry the settings its dialog took',
    (name, owner) => {
      const option = listOption(name);
      childPendingSettingsStore(option, owner).Draft = {
        name: 'Draft',
        staged: 'yes',
      };

      expect(option.stagedChildSettings(owner, 'Draft')).toEqual({
        name: 'Draft',
        staged: 'yes',
      });
      expect(hasDialog(option, owner, 'Draft')).toBe(true);
    },
  );

  it.each([['urltest', 'vpn']])(
    '%s shows the name a draft dialog holds',
    (name, owner) => {
      const option = listOption(name);
      childPendingSettingsStore(option, owner).Renamed = { name: 'Renamed' };

      expect(option.inputValueForItem(owner, 'Renamed')).toBe('Renamed');
    },
  );

  it.each([['urltest', 'urltest_stored', 'Fastest', 'vpn']])(
    '%s shows the stored name of a saved entry',
    (name, itemId, shown, owner) => {
      expect(listOption(name).inputValueForItem(owner, itemId)).toBe(shown);
    },
  );

  it('offers no dialog for a subscription address that is no entry', () => {
    const option = listOption('subscription_url');

    expect(hasDialog(option, 'vpn', 'https://example.com/other')).toBe(false);
  });

  it.each([
    ['urltest', 'vpn'],
    ['fallback_group', 'vpn'],
  ])('%s offers no dialog for an entry with no text', (name, owner) => {
    expect(hasDialog(listOption(name), owner, '')).toBe(false);
  });

  it('keeps a tunnel entry addressed by its section id', () => {
    const option = listOption('tunnels');
    childPendingSettingsStore(option, 'vpn').tunnel_abc = { name: 'Office' };

    expect(option.inputValueForItem('vpn', 'tunnel_abc')).toBe('tunnel_abc');
  });

  it.each([
    ['subscription_url', 'vpn'],
    ['interfaces', 'vpn'],
    ['urltest', 'vpn'],
  ])('%s forgets what it staged once the list is written', (name, owner) => {
    const option = listOption(name);
    childPendingSettingsStore(option, owner).Draft = { name: 'Draft' };

    option.clearStagedChildSettings(owner);

    expect(childPendingSettingsStore(option, owner)).toEqual({});
  });
});
