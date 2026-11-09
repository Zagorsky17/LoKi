import fs from 'fs';

import { beforeEach, describe, expect, it } from 'vitest';

import { ROOT } from '../lib/paths.js';
import { createHarness } from '../lib/luciForm.js';

let harness;

beforeEach(() => {
  harness = createHarness();
});

const SAMPLE_VALUE = {
  subscription_url: 'https://example.com/sub',
  section_interface: 'lan1',
  urltest: 'group1',
  fallback_group: 'fallback1',
  fallback_level: 'level1',
  tunnel: 'tunnel1',
  tunnel_peer: 'peer1',
};
const TYPE_BY_OPTION = { peer_ids: 'tunnel_peer' };

async function parseEveryOption(section, sid) {
  for (const option of section.children) {
    await Promise.resolve()
      .then(() => option.parse(sid))
      .catch(() => {});
  }
}

let probeCounter = 0;

function createItem(ownerId, option, typeName) {
  probeCounter += 1;
  const itemId = `${typeName}_probe_${probeCounter}`;
  const value = SAMPLE_VALUE[typeName] || 'probe';
  harness.uci.add('loki', typeName, itemId);
  harness.uci.set('loki', itemId, option.ownerOption || 'section', ownerId);
  if (option.childValueOption) {
    harness.uci.set('loki', itemId, option.childValueOption, value);
  }
  Object.entries(option.childDefaults || {}).forEach(([key, raw]) => {
    const resolved =
      typeof raw === 'function' ? raw(value, ownerId, itemId) : raw;
    if (resolved === undefined || resolved === null || resolved === '') return;
    harness.uci.set(
      'loki',
      itemId,
      key,
      Array.isArray(resolved)
        ? resolved.map((item) => `${item || ''}`).filter(Boolean)
        : `${resolved}`,
    );
  });
  return itemId;
}

async function checkDialog(problems, ownerId, option) {
  const typeName = option.childType || TYPE_BY_OPTION[option.option];
  if (!typeName || typeof option.renderItemSettingsModal !== 'function') return;

  const itemId = createItem(ownerId, option, typeName);
  const stored = JSON.stringify(harness.uci.get('loki', itemId));
  harness.operations.length = 0;

  let dialog;
  try {
    dialog = await harness.openDialog(option, ownerId, itemId);
  } catch (error) {
    problems.push(`${option.option}: ${error.message}`);
    return;
  }
  try {
    await dialog.save();
  } catch (error) {
    problems.push(
      `${option.option}: saving the dialog threw: ${error && error.message}`,
    );
    return;
  }

  if (harness.operations.length) {
    problems.push(
      `saving the ${typeName} dialog without a change rewrote the section: ` +
        `${harness.operations.join(', ')} (stored ${stored})`,
    );
  }
  harness.operations.length = 0;

  for (const child of dialog.map.children.flatMap(
    (section) => section.children,
  )) {
    if (
      typeof child.renderItemSettingsModal === 'function' &&
      (child.childType || TYPE_BY_OPTION[child.option])
    ) {
      await checkDialog(problems, itemId, child);
    }
  }
}

describe('a child item dialog', () => {
  it('writes nothing when it is saved unchanged', async () => {
    const view = harness.bundle;

    harness.uci.add('loki', 'section', 'section_probe');
    harness.uci.set('loki', 'section_probe', 'action', 'connection');
    harness.uci.set('loki', 'section_probe', 'enabled', '1');
    harness.uci.set('loki', 'section_probe', 'label', 'Section #1');

    const map = new harness.form.Map('loki');
    const connection = map.section(harness.form.GridSection, 'section');
    view.createSectionContent(connection);

    const found = [...connection.children]
      .filter(
        (option) =>
          typeof option.renderItemSettingsModal === 'function' &&
          (option.childType || TYPE_BY_OPTION[option.option]),
      )
      .map((option) => option.option);
    for (const expected of ['subscription_url', 'interfaces', 'urltest']) {
      expect(found, `the ${expected} dialog was not found`).toContain(expected);
    }

    const problems = [];
    for (const option of connection.children) {
      await checkDialog(problems, 'section_probe', option);
    }

    expect(problems.join('\n')).toBe('');
  });
});

function probeFormValue(option) {
  const cls = option.__name__ || '';
  const choices = (option.keylist || []).filter((key) => `${key ?? ''}` !== '');
  const other = choices.filter((key) => `${key}` !== `${option.default}`);
  const pick = other.length
    ? `${other[0]}`
    : choices.length
      ? `${choices[0]}`
      : '';
  if (cls === 'CBI.FlagValue') return `${option.default}` === '1' ? '0' : '1';
  if (cls === 'CBI.DynamicList' || cls === 'CBI.MultiValue') {
    return [pick || 'probe-value'];
  }
  if (pick) return pick;
  if (/port/.test(`${option.datatype ?? ''}`) || /_port$/.test(option.option)) {
    return '18080';
  }
  if (/range|uinteger/.test(`${option.datatype ?? ''}`)) return '1280';
  return 'probe-value';
}

function buildSection(action) {
  const view = harness.bundle;
  harness.uci.add('loki', 'section', 'probe');
  Object.assign(harness.store.get('probe'), {
    action,
    enabled: '1',
    label: 'Probe',
  });
  const map = new harness.form.Map('loki');
  const grid = map.section(harness.form.GridSection, 'section');
  view.configureSectionSection(grid);
  delete grid.load;
  view.createSectionContent(grid);
  return { section: grid, sid: 'probe' };
}

function buildSettings() {
  const view = harness.bundle;
  harness.uci.add('loki', 'settings', 'settings');
  harness.uci.add('loki', 'section', 'live');
  Object.assign(harness.store.get('live'), {
    action: 'connection',
    enabled: '1',
    label: 'Live',
  });
  const map = new harness.form.Map('loki');
  const settings = map.section(harness.form.NamedSection, 'settings');
  view.createSettingsContent(settings);
  return { section: settings, sid: 'settings' };
}

async function roundTrip(build, state, selector) {
  const { section, sid } = build(state);
  section.cfgsections = () => [sid];
  await section.load();

  const filled = [];
  for (const option of section.children) {
    if (option.option === selector || option.option === 'enabled') continue;
    if (['CBI.DummyValue', 'CBI.ButtonValue'].includes(option.__name__)) {
      continue;
    }
    const value = probeFormValue(option);
    option.formvalue = () => value;
    filled.push(option.option);
  }
  await parseEveryOption(section, sid);
  section.children.forEach((option) => delete option.formvalue);

  await section.load();
  harness.operations.length = 0;
  await parseEveryOption(section, sid);
  return { filled, operations: harness.operations.slice() };
}

const choicesOf = async (build, seed, name) => {
  const scratch = createHarness();
  const previous = harness;
  harness = scratch;
  try {
    const { section, sid } = build(seed);
    section.cfgsections = () => [sid];
    await section.load();
    return (
      section.children.find((option) => option.option === name)?.keylist || []
    ).slice();
  } finally {
    harness = previous;
  }
};

const ACTIONS = await choicesOf(buildSection, 'connection', 'action');

it('the action dropdown offers the remaining routing actions', () => {
  expect(ACTIONS.length).toBeGreaterThanOrEqual(4);
});

describe.each([
  ['a section', ACTIONS, 'action'],
  ['the Settings page', [''], null],
])('%s', (label, states, selector) => {
  const build = label === 'a section' ? buildSection : buildSettings;

  it.each(states)(
    'writes nothing when a form it filled in itself is saved again (%s)',
    async (state) => {
      const { filled, operations } = await roundTrip(build, state, selector);

      expect(
        filled.length,
        'too few fields were filled for this to check anything',
      ).toBeGreaterThanOrEqual(3);
      expect(operations.join(', ')).toBe('');
    },
  );
});

it('the Settings page writes nothing when the shipped config is saved', async () => {
  let current = null;
  const source = fs.readFileSync(`${ROOT}/loki/files/etc/config/loki`, 'utf8');
  for (const rawLine of source.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    let matched = /^config\s+(\S+)(?:\s+'([^']*)')?/.exec(line);
    if (matched) {
      current = harness.uci.add('loki', matched[1], matched[2] || undefined);
      continue;
    }
    matched = /^option\s+(\S+)\s+'([^']*)'/.exec(line);
    if (matched && current) {
      harness.store.get(current)[matched[1]] = matched[2];
      continue;
    }
    matched = /^list\s+(\S+)\s+'([^']*)'/.exec(line);
    if (matched && current) {
      const section = harness.store.get(current);
      section[matched[1]] = (section[matched[1]] || []).concat(matched[2]);
    }
  }
  expect(
    harness.uci.get('loki', 'settings'),
    'the shipped config has no settings section',
  ).toBeTruthy();

  const map = new harness.form.Map('loki');
  const section = map.section(harness.form.NamedSection, 'settings');
  harness.bundle.createSettingsContent(section);
  await section.load();
  harness.operations.length = 0;
  await section.parse();

  expect(harness.operations.join(', ')).toBe('');
});

describe('a subscription tag', () => {
  let list;
  const findOption = (dialog, name) =>
    dialog.map.children[0].children.find((option) => option.option === name);

  beforeEach(() => {
    harness.uci.add('loki', 'section', 'section_probe');
    harness.uci.set('loki', 'section_probe', 'action', 'connection');

    const map = new harness.form.Map('loki');
    const connection = map.section(harness.form.GridSection, 'section');
    harness.bundle.createSectionContent(connection);
    list = connection.children.find(
      (option) => option.option === 'subscription_url',
    );

    ['sub_first', 'sub_second'].forEach((itemId, index) => {
      harness.uci.add('loki', 'subscription_url', itemId);
      harness.uci.set('loki', itemId, 'section', 'section_probe');
      harness.uci.set('loki', itemId, 'url', `https://example.com/${index}`);
      harness.uci.set('loki', itemId, 'tag', `sub${index + 1}`);
    });
    list.cfgvalue('section_probe', ['sub_first', 'sub_second']);
  });

  it('is shown and kept by a save that does not change it', async () => {
    const dialog = await harness.openDialog(
      list,
      'section_probe',
      'sub_second',
    );
    const tag = findOption(dialog, 'tag');

    expect(tag, 'the subscription dialog has no tag field').toBeTruthy();
    expect(tag.isActive('settings'), 'the tag field is hidden').toBe(true);

    await dialog.save();

    expect(harness.uci.get('loki', 'sub_second', 'tag')).toBe('sub2');
  });

  it('is refused when another subscription already uses it', async () => {
    const dialog = await harness.openDialog(
      list,
      'section_probe',
      'sub_second',
    );

    expect(findOption(dialog, 'tag').validate('settings', 'sub1')).not.toBe(
      true,
    );
  });
});

describe.each(['connection', 'bypass', 'block', 'dns'])(
  'saving a %s section',
  (action) => {
    beforeEach(async () => {
      harness.uci.add('loki', 'section', 'section_probe');
      Object.assign(harness.store.get('section_probe'), {
        action,
        enabled: '1',
        label: 'Probe',
        rule_set: ['https://example.com/list.srs'],
        rule_set_with_subnets: ['https://example.com/list.srs'],
        community_lists: ['youtube'],
      });

      const map = new harness.form.Map('loki');
      const grid = map.section(harness.form.GridSection, 'section');
      harness.bundle.createSectionContent(grid);
      grid.cfgsections = () => ['section_probe'];
      await grid.load();
      await parseEveryOption(grid, 'section_probe');
    });

    it('keeps its rule sets', () => {
      expect(`${harness.uci.get('loki', 'section_probe', 'rule_set')}`).toBe(
        'https://example.com/list.srs',
      );
    });

    it('keeps the subnets flag of its rule set', () => {
      expect(
        `${harness.uci.get('loki', 'section_probe', 'rule_set_with_subnets')}`,
      ).toBe('https://example.com/list.srs');
    });

    it('keeps its built-in lists', () => {
      expect(
        `${harness.uci.get('loki', 'section_probe', 'community_lists')}`,
      ).toBe('youtube');
    });
  },
);

describe('a value behind a switch that is off', () => {
  it('survives a save of the Settings page', async () => {
    harness.uci.add('loki', 'settings', 'settings');
    Object.assign(harness.store.get('settings'), {
      config_version: '2.0.0',
      enable_native_api: '0',
      native_api_secret: 'api-secret',
      list_update_enabled: '0',
      update_interval: '6h',
    });
    const map = new harness.form.Map('loki');
    const section = map.section(harness.form.NamedSection, 'settings');
    harness.bundle.createSettingsContent(section);
    section.cfgsections = () => ['settings'];
    await section.load();
    await parseEveryOption(section, 'settings');

    for (const [name, value] of [
      ['native_api_secret', 'api-secret'],
      ['update_interval', '6h'],
      // Without it the next install or start takes the configuration for a foreign one.
      ['config_version', '2.0.0'],
    ])
      expect(harness.uci.get('loki', 'settings', name), name).toBe(value);
  });
});

describe('a number the backend reads as digits only', () => {
  function settingsOption(name) {
    harness.uci.add('loki', 'settings', 'settings');
    const map = new harness.form.Map('loki');
    const section = map.section(harness.form.NamedSection, 'settings');
    harness.bundle.createSettingsContent(section);
    return section.children.find((option) => option.option === name);
  }

  it.each([
    ['dns_rewrite_ttl', '30s'],
    ['badwan_reload_delay', '2s'],
  ])('%s refuses %s', (name, value) => {
    const option = settingsOption(name);

    expect(option.validate('settings', value)).not.toBe(true);
    expect(option.validate('settings', '300')).toBe(true);
  });
});

describe('session-authenticated YACD access', () => {
  it.each([
    {},
    { enable_yacd: '1' },
    { enable_yacd: '0', enable_yacd_wan_access: '1' },
    {
      enable_yacd: '1',
      enable_yacd_wan_access: '1',
      yacd_secret_key: 'synthetic-retired-key',
    },
  ])(
    'has no browser controller key or raw WAN control with %o',
    async (values) => {
      harness.uci.add('loki', 'settings', 'settings');
      Object.assign(harness.store.get('settings'), values);
      const map = new harness.form.Map('loki');
      const section = map.section(harness.form.NamedSection, 'settings');
      harness.bundle.createSettingsContent(section);
      section.cfgsections = () => ['settings'];
      await section.load();
      const names = section.children.map((option) => option.option);
      expect(names).not.toContain('yacd_secret_key');
      expect(names).not.toContain('enable_yacd_wan_access');
      expect(names).not.toContain('enable_yacd');
      const option = section.children.find(
        (item) => item.option === '_yacd_link',
      );
      expect(option.cfgvalue()).toContain(
        'https://router.lan:9091/cgi-bin/luci/loki-gateway/',
      );
      expect(option.cfgvalue()).toContain('rel="noopener noreferrer"');
      expect(option.cfgvalue()).not.toMatch(
        /secret=|token=|synthetic-retired-key/,
      );
    },
  );
});

describe('LoKi configuration identity', () => {
  it('survives editing settings without becoming a user option', async () => {
    harness.uci.add('loki', 'settings', 'settings');
    harness.uci.set('loki', 'settings', 'config_format', 'loki');
    harness.uci.set('loki', 'settings', 'config_version', '2.0.0');
    const map = new harness.form.Map('loki');
    const settings = map.section(harness.form.TypedSection, 'settings');
    harness.bundle.createSettingsContent(settings);
    expect(settings.children.map((option) => option.option)).not.toContain(
      'config_format',
    );
    await parseEveryOption(settings, 'settings');
    expect(harness.uci.get('loki', 'settings', 'config_format')).toBe('loki');
    expect(harness.uci.get('loki', 'settings', 'config_version')).toBe('2.0.0');
  });
});
