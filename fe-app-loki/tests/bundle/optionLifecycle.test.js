import { beforeEach, describe, expect, it } from 'vitest';

import { createHarness } from '../lib/luciForm.js';

const ALL_PROVIDERS = {
  zapretInstalled: true,
  zapret2Installed: true,
  byedpiInstalled: true,
};
const NO_PROVIDERS = {
  zapretInstalled: false,
  zapret2Installed: false,
  byedpiInstalled: false,
};

let harness;

beforeEach(() => {
  harness = createHarness();
});

function addSections(list) {
  list.forEach(([type, sid, values]) => {
    harness.uci.add('loki', type, sid);
    Object.assign(harness.store.get(sid), values);
  });
  harness.operations.length = 0;
}

function sectionGrid(providers = ALL_PROVIDERS) {
  const view = harness.bundle;
  const map = new harness.form.Map('loki');
  const grid = map.section(harness.form.GridSection, 'section');
  view.configureSectionSection(grid, {
    loadActionProvidersAvailability: () => Promise.resolve(providers),
  });
  delete grid.load;
  view.createSectionContent(grid);
  return grid;
}

async function parseEveryOption(grid, sid) {
  grid.cfgsections = () => [sid];
  await grid.load();
  for (const option of grid.children) {
    await Promise.resolve()
      .then(() => option.parse(sid))
      .catch(() => {});
  }
}

function widgetAnswers(grid, values) {
  Object.entries(values).forEach(([name, value]) => {
    grid.children.find((option) => option.option === name).formvalue = () =>
      value;
  });
}

function itemsOfType(type) {
  return harness.uci
    .sections('loki', type)
    .map((item) => item['.name'])
    .sort();
}

const CONNECTION_SECTION = [
  'section',
  'sec',
  {
    action: 'connection',
    enabled: '1',
    label: 'proxy',
    destinations: 'example.com',
    outbound_jsons: [
      '{"type":"socks","tag":"local","server":"127.0.0.1","server_port":1080}',
    ],
  },
];

function connectionChildren() {
  return [
    CONNECTION_SECTION,
    [
      'connection_link',
      'link1',
      {
        section: 'sec',
        uri: 'vless://a@example:1?type=tcp#node',
        name: 'node',
        order: '0',
      },
    ],
    [
      'subscription_url',
      'sub1',
      {
        section: 'sec',
        url: 'https://example.com/sub',
        tag: 'sub1',
        server_filter_mode: 'all',
        subscription_update_enabled: '1',
        subscription_update_interval: '1h',
        download_via_proxy_enabled: '0',
        show_dashboard_metadata: '1',
      },
    ],
    [
      'section_interface',
      'iface1',
      {
        section: 'sec',
        name: 'wan',
        display_name: 'WAN',
        domain_resolver_enabled: '0',
      },
    ],
    [
      'urltest',
      'ut1',
      {
        section: 'sec',
        name: 'URLTest #1',
        check_interval: '3m',
        tolerance: '50',
        testing_url: 'https://www.gstatic.com/generate_204',
        expected_status: '*',
        idle_timeout: '30m',
        interrupt_exist_connections: '0',
        server_filter_mode: 'all',
      },
    ],
    [
      'fallback_group',
      'grp1',
      {
        section: 'sec',
        name: 'Fallback #1',
        health_check_url: 'https://www.gstatic.com/generate_204',
        health_check_interval: '5m',
        health_check_timeout: '5s',
        attempt_timeout: '5s',
        expected_status: '*',
        idle_timeout: '5m',
        interrupt_exist_connections: '0',
      },
    ],
    [
      'fallback_level',
      'lvl1',
      {
        group: 'grp1',
        name: 'Group #1',
        order: '0',
        server_filter_mode: 'direct',
      },
    ],
  ];
}

const CHILD_TYPES = [
  'connection_link',
  'subscription_url',
  'section_interface',
  'urltest',
  'fallback_group',
  'fallback_level',
];
const EVERY_CHILD = ['grp1', 'iface1', 'link1', 'lvl1', 'sub1', 'ut1'];

function survivingChildren() {
  return CHILD_TYPES.flatMap((type) => itemsOfType(type)).sort();
}

describe('a list the dialog hides keeps its items', () => {
  it.each(['bypass', 'block', 'dns', 'zapret'])(
    'changing a Connection section to %s keeps everything under it',
    async (action) => {
      addSections(connectionChildren());
      const grid = sectionGrid();
      grid.cfgsections = () => ['sec'];
      await grid.load();
      widgetAnswers(grid, { action });
      for (const option of grid.children) {
        await Promise.resolve()
          .then(() => option.parse('sec'))
          .catch(() => {});
      }

      expect(survivingChildren()).toEqual(EVERY_CHILD);
      expect(harness.uci.get('loki', 'sec', 'outbound_jsons')).toBeTruthy();
    },
  );
});

describe('the destinations of a section', () => {
  const FIELDS = [
    [
      'a Connection section',
      'connection',
      'destinations',
      'example.org\n192.0.2.0/24',
    ],
    ['a DNS section', 'dns', '_dns_destinations', 'example.org'],
  ];

  async function saveAs(action, destinations, answers = {}) {
    addSections([
      [
        'section',
        'sec',
        { action, enabled: '1', dns_server: ['tls://1.1.1.1'], destinations },
      ],
    ]);
    const grid = sectionGrid();
    grid.cfgsections = () => ['sec'];
    await grid.load();
    widgetAnswers(grid, answers);
    for (const option of grid.children) {
      await Promise.resolve()
        .then(() => option.parse('sec'))
        .catch(() => {});
    }
    return harness.uci.get('loki', 'sec', 'destinations');
  }

  it.each(FIELDS)(
    'survive a save of %s',
    async (_label, action, _field, text) => {
      expect(await saveAs(action, text)).toBe(text);
    },
  );

  it.each(FIELDS)(
    'are what the field of %s says after an edit',
    async (_label, action, field) => {
      expect(
        await saveAs(action, 'old.example', { [field]: 'new.example' }),
      ).toBe('new.example');
    },
  );

  it.each(FIELDS)(
    'leave with the text the field of %s was emptied of',
    async (_label, action, field) => {
      expect(await saveAs(action, 'old.example', { [field]: '' })).toBeNull();
    },
  );

  it('survive a save of a section whose action shows neither field', async () => {
    expect(await saveAs('zapret', 'example.org')).toBe('example.org');
  });
});

describe('a subscription is named when its link is added', () => {
  const LINKS = ['https://a.example/sub', 'https://b.example/sub'];

  async function subscriptionList(sections) {
    addSections(sections);
    const grid = sectionGrid();
    grid.cfgsections = () => ['sec'];
    await grid.load();
    const list = grid.children.find(
      (option) => option.option === 'subscription_url',
    );
    const values = [...list.cfgvalue('sec')];
    list.formvalue = () => values.slice();
    return {
      grid,
      list,
      values,
      add(source) {
        values.push(list.createTypedItem('sec', source));
        return values[values.length - 1];
      },
    };
  }

  async function saveSection(grid) {
    for (const option of grid.children) {
      await Promise.resolve()
        .then(() => option.parse('sec'))
        .catch(() => {});
    }
  }

  function storedTags() {
    return harness.uci
      .sections('loki', 'subscription_url')
      .map((item) => item.tag);
  }

  it('writes a tag for a link whose dialog was never opened', async () => {
    const { grid, add } = await subscriptionList([CONNECTION_SECTION]);
    LINKS.forEach(add);

    await saveSection(grid);

    expect(storedTags()).toEqual(['sub1', 'sub2']);
  });

  it('numbers a new link after the subscription the section has', async () => {
    const { grid, add } = await subscriptionList(connectionChildren());
    add(LINKS[0]);

    await saveSection(grid);

    expect(storedTags().sort()).toEqual(['sub1', 'sub2']);
  });

  it('names a link typed and saved without being added', async () => {
    const { grid, list, values, add } = await subscriptionList([
      CONNECTION_SECTION,
    ]);
    add(LINKS[0]);
    list.formvalue = () => [...values, LINKS[1]];

    await saveSection(grid);

    expect(storedTags()).toEqual(['sub1', 'sub2']);
  });

  it('does not name two subscriptions the same', async () => {
    const { grid, list, add } = await subscriptionList([CONNECTION_SECTION]);
    add(LINKS[0]);
    const second = add(LINKS[1]);

    const dialog = await harness.openDialog(list, 'sec', second);
    const tag = dialog.map.children[0].children.find(
      (option) => option.option === 'tag',
    );
    expect(tag.cfgvalue('settings')).toBe('sub2');
    await dialog.save();
    await saveSection(grid);

    expect(storedTags().sort()).toEqual(['sub1', 'sub2']);
  });
});

describe('a list the user can see owns its items', () => {
  it('clearing a fallback list removes its levels and leaves subscriptions intact', async () => {
    addSections(connectionChildren());
    const grid = sectionGrid();
    grid.cfgsections = () => ['sec'];
    await grid.load();
    widgetAnswers(grid, { fallback_group: [] });
    for (const option of grid.children) await option.parse('sec');
    expect(itemsOfType('fallback_group')).toEqual([]);
    expect(itemsOfType('fallback_level')).toEqual([]);
    expect(itemsOfType('subscription_url')).toEqual(['sub1']);
  });

  it('removing one fallback group removes exactly that group', async () => {
    addSections(connectionChildren());
    harness.uci.add('loki', 'fallback_group', 'grp2');
    Object.assign(harness.store.get('grp2'), {
      section: 'sec',
      name: 'Backup',
      order: '1',
    });
    const grid = sectionGrid();
    grid.cfgsections = () => ['sec'];
    await grid.load();
    widgetAnswers(grid, { fallback_group: ['grp1'] });
    for (const option of grid.children) await option.parse('sec');
    expect(itemsOfType('fallback_group')).toEqual(['grp1']);
    expect(itemsOfType('fallback_level')).toEqual(['lvl1']);
  });

  it('a fallback added and taken out again is gone after the save', async () => {
    addSections(connectionChildren());
    const grid = sectionGrid();
    grid.cfgsections = () => ['sec'];
    await grid.load();
    harness.uci.add('loki', 'fallback_group', 'grp2');
    Object.assign(harness.store.get('grp2'), {
      section: 'sec',
      name: 'Backup',
    });
    widgetAnswers(grid, { fallback_group: ['grp1'] });
    for (const option of grid.children) await option.parse('sec');
    expect(itemsOfType('fallback_group')).toEqual(['grp1']);
  });

  it('a save that changes nothing sets nothing on an item', async () => {
    addSections(connectionChildren());
    const grid = sectionGrid();
    grid.cfgsections = () => ['sec'];
    await grid.load();
    const sets = [];
    const set = harness.uci.set;
    harness.uci.set = (...args) => {
      if (args[1] !== 'sec') sets.push(args.slice(1).join(' '));
      return set.apply(harness.uci, args);
    };
    for (const option of grid.children) {
      await Promise.resolve()
        .then(() => option.parse('sec'))
        .catch(() => {});
    }
    harness.uci.set = set;

    expect(sets).toEqual([]);
  });
});

describe('removing an owner takes its children', () => {
  it('deleting a section takes everything under it', async () => {
    addSections(connectionChildren());
    const grid = sectionGrid();
    grid.handleRemove = () => Promise.resolve();
    harness.bundle.configureSectionSection(grid, {
      loadActionProvidersAvailability: () => Promise.resolve(ALL_PROVIDERS),
    });
    await grid.handleRemove('sec');

    expect(survivingChildren()).toEqual([]);
  });
});

const LIVE_SECTION = [
  'section',
  'live',
  {
    action: 'connection',
    enabled: '1',
    label: 'Live',
  },
];
const target = (enabled) => [
  'section',
  'target',
  {
    action: 'connection',
    enabled,
    label: 'Target',
  },
];

describe.each([
  ['its target was deleted', []],
  ['its target is switched off', [target('0')]],
])('a reference survives while %s', (_label, extra) => {
  it('on a DNS section', async () => {
    addSections([
      [
        'section',
        'sec',
        {
          action: 'dns',
          enabled: '1',
          label: 'DNS section',
          dns_server: ['tls://1.1.1.1'],
          destinations: 'example.com',
          dns_detour_enabled: '1',
          dns_detour_section: 'target',
        },
      ],
      LIVE_SECTION,
      ...extra,
    ]);
    await parseEveryOption(sectionGrid(), 'sec');

    expect(harness.uci.get('loki', 'sec', 'dns_detour_section')).toBe('target');
  });

  it('on every reference the Settings page holds', async () => {
    addSections([
      [
        'settings',
        'settings',
        {
          dns_server: ['tls://1.1.1.1'],
          bootstrap_dns_server: ['1.1.1.1'],
          dns_detour_enabled: '1',
          dns_detour_section: 'target',
          download_lists_via_proxy: '1',
          download_lists_via_proxy_section: 'target',
        },
      ],
      LIVE_SECTION,
      ...extra,
    ]);
    const map = new harness.form.Map('loki');
    const settingsSection = map.section(harness.form.NamedSection, 'settings');
    harness.bundle.createSettingsContent(settingsSection, {
      loaded: true,
      ...ALL_PROVIDERS,
    });
    await parseEveryOption(settingsSection, 'settings');

    for (const name of [
      'dns_detour_section',
      'download_lists_via_proxy_section',
    ]) {
      expect(harness.uci.get('loki', 'settings', name), name).toBe('target');
    }
  });

  it.each([
    [
      'subscription_url',
      'subscription_url',
      {
        url: 'https://example.com/sub',
        tag: 'sub1',
        server_filter_mode: 'all',
        subscription_update_enabled: '1',
        subscription_update_interval: '1h',
        download_via_proxy_enabled: '1',
        download_via_proxy_section: 'target',
        show_dashboard_metadata: '1',
      },
      'download_via_proxy_section',
    ],
    [
      'subscription_url',
      'subscription_url',
      {
        url: 'https://example.com/sub',
        tag: 'sub1',
        server_filter_mode: 'all',
        subscription_update_enabled: '1',
        subscription_update_interval: '1h',
        download_via_proxy_enabled: '0',
        show_dashboard_metadata: '1',
        detour_section: 'target',
      },
      'detour_section',
    ],
    [
      'connection_link',
      'connection_link',
      {
        uri: 'vless://o@example:1#n',
        name: 'n',
        order: '0',
        detour_section: 'target',
      },
      'detour_section',
    ],
    [
      'section_interface',
      'interfaces',
      {
        name: 'wan',
        display_name: 'WAN',
        domain_resolver_enabled: '1',
        domain_resolver_dns_server: ['tls://1.1.1.1'],
        domain_resolver_dns_detour_enabled: '1',
        domain_resolver_dns_detour_section: 'target',
      },
      'domain_resolver_dns_detour_section',
    ],
  ])('in the %s dialog', async (type, listName, seed, key) => {
    addSections([
      [
        'section',
        'owner',
        {
          action: 'connection',
          enabled: '1',
          label: 'Owner',
        },
      ],
      [type, 'item', { section: 'owner', ...seed }],
      LIVE_SECTION,
      ...extra,
    ]);
    const grid = sectionGrid();
    const list = grid.children.find((option) => option.option === listName);
    const dialog = await harness.openDialog(list, 'owner', 'item');
    const result = await dialog.save().catch(() => ({ saved: false }));

    expect(result.saved, `the ${type} dialog refused to save`).toBe(true);
    expect(harness.uci.get('loki', 'item', key)).toBe('target');
  });
});

it('a DNS detour survives a target whose provider is not installed', async () => {
  addSections([
    [
      'section',
      'sec',
      {
        action: 'dns',
        enabled: '1',
        label: 'DNS section',
        dns_server: ['tls://1.1.1.1'],
        destinations: 'example.com',
        dns_detour_enabled: '1',
        dns_detour_section: 'target',
      },
    ],
    LIVE_SECTION,
    [
      'section',
      'target',
      {
        action: 'zapret',
        enabled: '1',
        label: 'Target',
        nfqws_opt: '--dpi-desync=fake',
        destinations: 'example.com',
      },
    ],
  ]);
  await parseEveryOption(sectionGrid(NO_PROVIDERS), 'sec');

  expect(harness.uci.get('loki', 'sec', 'dns_detour_section')).toBe('target');
});

describe.each([
  ['zapret', 'nfqws_opt', '--dpi-desync=fake'],
  ['zapret2', 'nfqws2_opt', '--dpi-desync=fake'],
  ['byedpi', 'byedpi_cmd_opts', '-Kt,h'],
])(
  'a %s section whose provider is not installed',
  (action, field, strategy) => {
    beforeEach(async () => {
      addSections([
        [
          'section',
          'sec',
          {
            action,
            enabled: '1',
            label: 'DPI section',
            destinations: 'example.com',
            [field]: strategy,
          },
        ],
      ]);
      await parseEveryOption(sectionGrid(NO_PROVIDERS), 'sec');
    });

    it('keeps its action', () => {
      expect(harness.uci.get('loki', 'sec', 'action')).toBe(action);
    });

    it('keeps its strategy', () => {
      expect(harness.uci.get('loki', 'sec', field)).toBeTruthy();
    });
  },
);

it('adding a subscription writes no option nothing reads', async () => {
  addSections([CONNECTION_SECTION]);
  const grid = sectionGrid();
  grid.cfgsections = () => ['sec'];
  await grid.load();
  const list = grid.children.find(
    (option) => option.option === 'subscription_url',
  );
  list.formvalue = () => ['https://example.com/new'];
  await Promise.resolve()
    .then(() => list.parse('sec'))
    .catch(() => {});

  const added = harness.uci
    .sections('loki', 'subscription_url')
    .find((item) => item.url === 'https://example.com/new');
  expect(added, 'no subscription section was created').toBeTruthy();
  expect(added.user_agent).toBeUndefined();
  expect(added.show_subscription_name).toBeUndefined();
});

describe('a nested dialog that refuses to save', () => {
  it('says why', async () => {
    addSections(connectionChildren());
    const grid = sectionGrid();
    const list = grid.children.find(
      (option) => option.option === 'connection_link',
    );
    const dialog = await harness.openDialog(list, 'sec', 'link1');
    // LuCI reports field validation failures from parse; the harness models its rejection.
    dialog.map.parse = () =>
      Promise.reject(new Error('Connection URI: Unsupported link'));
    const result = await dialog.save();
    expect(result.saved).toBe(false);
    expect(harness.toasts()).toEqual(['Connection URI: Unsupported link']);
  });
});

describe('a check behind a switch turned on in the same dialog', () => {
  function dialogOption(dialog, name) {
    return dialog.map.children[0].children.find(
      (option) => option.option === name,
    );
  }

  function turnOn(dialog, name) {
    dialogOption(dialog, name).formvalue = () => '1';
  }

  it('refuses a subscription requested through no section', async () => {
    addSections([CONNECTION_SECTION]);
    const grid = sectionGrid();
    grid.cfgsections = () => ['sec'];
    await grid.load();
    const list = grid.children.find(
      (option) => option.option === 'subscription_url',
    );
    const itemId = list.createTypedItem('sec', 'https://a.example/sub');
    widgetAnswers(grid, { subscription_url: [itemId] });
    const dialog = await harness.openDialog(list, 'sec', itemId);
    turnOn(dialog, 'download_via_proxy_enabled');

    expect(
      dialogOption(dialog, 'download_via_proxy_section').validate(
        'settings',
        '',
      ),
    ).toBe('Required');
  });

  it('checks the DNS servers of an interface resolver', async () => {
    addSections([
      [
        'section',
        'sec',
        { action: 'connection', enabled: '1', label: 'proxy' },
      ],
      [
        'section_interface',
        'iface1',
        {
          section: 'sec',
          name: 'wan',
          display_name: 'WAN',
          domain_resolver_enabled: '0',
        },
      ],
    ]);
    const grid = sectionGrid();
    const list = grid.children.find((option) => option.option === 'interfaces');
    const dialog = await harness.openDialog(list, 'sec', 'iface1');
    turnOn(dialog, 'domain_resolver_enabled');

    expect(
      dialogOption(dialog, 'domain_resolver_dns_server').validate(
        'settings',
        'not a server',
      ),
    ).not.toBe(true);
  });

  it('refuses an interface resolver sent through no section', async () => {
    addSections([
      [
        'section',
        'sec',
        { action: 'connection', enabled: '1', label: 'proxy' },
      ],
      [
        'section_interface',
        'iface1',
        {
          section: 'sec',
          name: 'wan',
          display_name: 'WAN',
          domain_resolver_enabled: '1',
          domain_resolver_dns_server: ['1.1.1.1'],
          domain_resolver_dns_detour_enabled: '0',
        },
      ],
    ]);
    const grid = sectionGrid();
    const list = grid.children.find((option) => option.option === 'interfaces');
    const dialog = await harness.openDialog(list, 'sec', 'iface1');
    turnOn(dialog, 'domain_resolver_dns_detour_enabled');

    expect(
      dialogOption(dialog, 'domain_resolver_dns_detour_section').validate(
        'settings',
        '',
      ),
    ).toBe('Required');
  });
});
