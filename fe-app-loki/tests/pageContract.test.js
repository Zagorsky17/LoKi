import fs from 'fs';
import path from 'path';

import { beforeEach, describe, expect, it } from 'vitest';

import { ROOT } from './lib/paths.js';
import { createHarness } from './lib/luciForm.js';
import {
  DOMAIN_LIST_OPTIONS,
  FAKEIP_CHECK_DOMAIN,
  RESERVED_RUNTIME_TAGS,
  REMOVED_VPN_TYPES,
} from '../src/constants';
import {
  groupTypeChoices,
  providerTypeChoices,
} from '../src/loki/tabs/sections/providers';
import { RESERVED_OVERRIDE_PATCH_PATHS } from '../src/loki/tabs/sections/subscriptions/overrides';
import {
  FALLBACK_DEFAULTS,
  URLTEST_DEFAULTS,
} from '../src/loki/methods/custom/getDashboardSections';
import { LOKI_WAIT_TIMEOUT_MS } from '../src/loki/services/lokiWaitTransport';
import { LOKI_ACTION_OPENINGS } from '../src/loki/services/logNotificationDeduper.service';
import {
  INSTALLER_ACTIONS,
  INSTALLER_OBJECT,
} from '../src/loki/tabs/components/installerApi';

const contract = JSON.parse(
  fs.readFileSync(path.join(ROOT, 'tests/fixtures/page_contract.json'), 'utf8'),
);

describe('the tables the page carries', () => {
  it('reserve the tags Loki uses', () => {
    expect([...RESERVED_RUNTIME_TAGS].sort()).toEqual(contract.reserved_tags);
  });

  it('offer the community rule sets the backend downloads', () => {
    expect(Object.keys(DOMAIN_LIST_OPTIONS).sort()).toEqual(
      contract.community_rule_sets,
    );
  });

  it('filter by the server types the backend accepts', () => {
    expect(providerTypeChoices().map(({ value }) => value)).toEqual(
      contract.provider_types,
    );
    expect(groupTypeChoices().map(({ value }) => value)).toEqual(
      contract.group_types,
    );
    expect(REMOVED_VPN_TYPES).toEqual(contract.removed_vpn_types);
  });

  it('refuse the override paths the backend refuses', () => {
    expect(RESERVED_OVERRIDE_PATCH_PATHS).toEqual(
      contract.reserved_override_patch_paths,
    );
  });

  it('check the domains the configuration answers for', () => {
    expect({ fakeip: FAKEIP_CHECK_DOMAIN }).toEqual(contract.check_domains);
  });

  it('describe an unset group option as the generator reads it', () => {
    expect(URLTEST_DEFAULTS).toEqual(contract.urltest_defaults);
    expect(FALLBACK_DEFAULTS).toEqual(contract.fallback_defaults);
  });

  it('wait for a parked request longer than the state service holds it', () => {
    expect(LOKI_WAIT_TIMEOUT_MS).toBeGreaterThan(contract.state_wait_ms);
  });

  it('close the alerts of earlier actions at the line a new one opens with', () => {
    expect(LOKI_ACTION_OPENINGS).toEqual(contract.action_openings);
  });
});

describe('a password field', () => {
  let harness;

  beforeEach(() => {
    harness = createHarness();
  });

  function passwordFields(options) {
    return options
      .filter((option) => option.password === true)
      .map((option) => option.option);
  }

  async function dialogPasswordFields(ownerId, option, found) {
    const typeName =
      option.childType || (option.option === 'peer_ids' ? 'tunnel_peer' : '');
    if (!typeName || typeof option.renderItemSettingsModal !== 'function') {
      return;
    }
    const itemId = `${typeName}_probe`;
    harness.uci.add('loki', typeName, itemId);
    harness.uci.set('loki', itemId, option.ownerOption || 'section', ownerId);
    const dialog = await harness.openDialog(option, ownerId, itemId);
    const options = dialog.map.children.flatMap((section) => section.children);
    for (const field of passwordFields(options)) {
      found.push({ field, typeName });
    }
    for (const child of options) {
      await dialogPasswordFields(itemId, child, found);
    }
  }

  async function renderedPasswordFields() {
    const view = harness.bundle;
    harness.uci.add('loki', 'settings', 'settings');
    harness.uci.add('loki', 'section', 'section_probe');
    harness.uci.set('loki', 'section_probe', 'action', 'connection');

    const sections = new harness.form.Map('loki').section(
      harness.form.GridSection,
      'section',
    );
    view.createSectionContent(sections);
    const settings = new harness.form.Map('loki').section(
      harness.form.NamedSection,
      'settings',
    );
    view.createSettingsContent(settings);

    const found = passwordFields([
      ...sections.children,
      ...settings.children,
    ]).map((field) => ({ field, typeName: '' }));
    for (const option of sections.children) {
      await dialogPasswordFields('section_probe', option, found);
    }
    return found;
  }

  it('is one the contract names', async () => {
    const found = await renderedPasswordFields();
    expect([...new Set(found.map(({ field }) => field))].sort()).toEqual(
      Object.keys(contract.password_fields).sort(),
    );
  });

  it('is stored in the option the contract says the diagnostics mask', async () => {
    const found = await renderedPasswordFields();
    for (const { field } of found) {
      expect(contract.password_fields[field], field).toBe(field);
    }
  });
});

describe('the installer', () => {
  it('is followed through the object its runner publishes, with the methods the ACL grants', () => {
    expect(INSTALLER_OBJECT).toBe(contract.installer.object);
    expect([...INSTALLER_ACTIONS]).toEqual(contract.installer.actions);
    const acl = JSON.parse(
      fs.readFileSync(
        path.join(
          ROOT,
          'luci-app-loki/root/usr/share/rpcd/acl.d/luci-app-loki.json',
        ),
        'utf8',
      ),
    );
    expect(
      [
        ...acl['luci-app-loki'].read.ubus[INSTALLER_OBJECT],
        ...acl['luci-app-loki'].write.ubus[INSTALLER_OBJECT],
      ].sort(),
    ).toEqual(contract.installer.methods);
    expect(acl['luci-app-loki'].read.ubus[INSTALLER_OBJECT]).toEqual(['read']);
    expect(acl['luci-app-loki'].write.ubus[INSTALLER_OBJECT]).toEqual([
      'input',
      'stop',
    ]);
  });
});
