import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ providers: vi.fn() }));
vi.mock('../../../methods/custom/clashApi', () => ({
  getClashApiProxyProviders: mocks.providers,
}));

import { installLuciStubs } from '../../../../helpers/tests/luciStubs';
import { childPendingSettingsStore } from '../../../cbi/itemSettings';
import {
  currentDraftOutboundNames,
  currentLiveDynamicListValues,
  currentOutboundNameChoices,
  currentSubscriptionOutboundNameChoices,
  forgetOutboundNameChoices,
  loadProviderServerNames,
  nextSectionChildName,
  outboundNameChoiceItems,
  outboundNameSourceOptions,
  providerServerNameMap,
  validateSectionChildName,
} from '../outboundNames';

const PAYLOAD = {
  providers: {
    'Main/sub1': {
      proxies: [
        { name: 'Main/sub1/Zurich', type: 'VLESS' },
        { name: 'Main/sub1/Amsterdam', type: 'AnyTLS' },
        { name: 'Main/sub1/Auto', type: 'URLTest' },
      ],
      filterCandidates: ['Zurich', 'Amsterdam'],
    },
    'Main/sub2': {
      proxies: [
        { name: 'Main/sub2/Berlin', type: 'VLESS' },
        { name: 'Main/sub2/Hop', type: 'VLESS' },
      ],
      filterCandidates: ['Berlin', 'Oslo', 'Hop'],
    },
    'Other/sub1': {
      proxies: [{ name: 'Other/sub1/Tokyo', type: 'VLESS' }],
    },
  },
};

const clashAnswer = (value: unknown) => ({ success: true, data: value });

function answerWith(next: Promise<unknown>) {
  mocks.providers.mockImplementation(() => next);
}

const listed = (values: string[]) => ({ formvalue: () => values });

beforeEach(() => {
  mocks.providers.mockReset();
  answerWith(Promise.resolve(clashAnswer(PAYLOAD)));
  installLuciStubs({});
  forgetOutboundNameChoices();
});

afterEach(() => {
  vi.useRealTimers();
  outboundNameSourceOptions.clear();
});

describe('providerServerNameMap', () => {
  it("keeps each provider's servers in its own order, without their prefix", () => {
    expect(providerServerNameMap(PAYLOAD).get('Main/sub1')?.imported).toEqual([
      'Zurich',
      'Amsterdam',
    ]);
  });

  it('leaves the groups the core built out of them alone', () => {
    expect(
      providerServerNameMap(PAYLOAD).get('Main/sub1')?.imported,
    ).not.toContain('Auto');
  });
});

describe('the server choices of a section', () => {
  // As LuCI holds them while the dialog is open: a subscription taken out of the list keeps its
  // section until the dialog is saved.
  function section(subscriptions: string[]) {
    const stub = installLuciStubs({
      main: { '.type': 'section', label: 'Main' },
      first: {
        '.type': 'subscription_url',
        section: 'main',
        tag: 'sub1',
      },
      second: {
        '.type': 'subscription_url',
        section: 'main',
        tag: 'sub2',
      },
      germany: {
        '.type': 'connection_link',
        section: 'main',
        uri: 'vless://a.test#A',
        name: 'Germany',
      },
      uplink: {
        '.type': 'section_interface',
        section: 'main',
        name: 'wan',
        display_name: 'Uplink',
      },
      wg: { '.type': 'tunnel', section: 'main', name: 'Warp' },
    });
    outboundNameSourceOptions.set('connection_link', listed(['germany']));
    outboundNameSourceOptions.set('interfaces', {
      sharedPendingSettingsKey: 'interfaces',
      ...listed(['uplink']),
    });
    outboundNameSourceOptions.set('tunnels', listed(['wg']));
    outboundNameSourceOptions.set(
      'outbound_jsons',
      listed(['{"type":"socks","tag":"Hop"}']),
    );
    outboundNameSourceOptions.set('urltest', listed([]));
    outboundNameSourceOptions.set('fallback_group', listed([]));
    outboundNameSourceOptions.set('subscription_url', listed(subscriptions));
    return stub;
  }

  const choiceValues = (choices: Array<{ value: string }>) =>
    choices.map((choice) => choice.value);

  it("list the section's own servers before the subscriptions, as the dashboard does", async () => {
    section(['first', 'second']);
    await loadProviderServerNames();

    expect(choiceValues(currentOutboundNameChoices('main'))).toEqual([
      'Germany',
      'Uplink',
      'Hop',
      'Zurich',
      'Amsterdam',
      'Berlin',
    ]);
  });

  it('follow the order of the subscriptions in the list', async () => {
    section(['second', 'first']);
    await loadProviderServerNames();

    expect(choiceValues(currentOutboundNameChoices('main')).slice(3)).toEqual([
      'Berlin',
      'Zurich',
      'Amsterdam',
    ]);
  });

  it('lose the servers of a subscription the moment it leaves the list', async () => {
    section(['first', 'second']);
    await loadProviderServerNames();
    outboundNameSourceOptions.set('subscription_url', listed(['second']));

    expect(choiceValues(currentOutboundNameChoices('main'))).not.toContain(
      'Zurich',
    );
  });

  it('of a subscription are every server its filter chooses from, those it drops included', async () => {
    section(['first', 'second']);
    await loadProviderServerNames();

    expect(
      choiceValues(currentSubscriptionOutboundNameChoices('main', 'second')),
    ).toEqual(['Berlin', 'Oslo', 'Hop']);
  });

  it('keep the servers of a subscription renamed in the open dialog', async () => {
    const stub = section(['first', 'second']);
    const loadedGet = stub.get;
    // uci.js answers the dialog's edits while state.values keeps what was loaded.
    stub.get = (config: string, sid: string, option?: string) =>
      sid === 'first' && option === 'tag'
        ? 'renamed'
        : sid === 'main' && option === 'label'
          ? 'Renamed'
          : loadedGet(config, sid, option);
    await loadProviderServerNames();

    expect(choiceValues(currentOutboundNameChoices('main'))).toContain(
      'Zurich',
    );
    expect(
      choiceValues(currentSubscriptionOutboundNameChoices('main', 'first')),
    ).toEqual(['Zurich', 'Amsterdam']);
  });

  it('ask the core nothing for a section without subscriptions', () => {
    section([]);

    expect(choiceValues(currentOutboundNameChoices('main'))).toEqual([
      'Germany',
      'Uplink',
      'Hop',
    ]);
    expect(mocks.providers).not.toHaveBeenCalled();
  });

  it('keep the own servers while the core is unavailable', async () => {
    section(['first']);
    answerWith(
      Promise.resolve({ success: false, error: 'sing-box is unavailable' }),
    );
    await loadProviderServerNames();

    expect(choiceValues(currentOutboundNameChoices('main'))).toEqual([
      'Germany',
      'Uplink',
      'Hop',
    ]);
  });

  it('ask the core again once an answer lacking a subscription goes stale', async () => {
    section(['first']);
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-01-01T00:00:00Z'));
    answerWith(Promise.resolve(clashAnswer({ providers: {} })));
    await loadProviderServerNames();

    answerWith(Promise.resolve(clashAnswer(PAYLOAD)));
    currentOutboundNameChoices('main');
    expect(mocks.providers).toHaveBeenCalledTimes(1);

    vi.setSystemTime(new Date('2026-01-01T00:01:00Z'));
    currentOutboundNameChoices('main');
    await loadProviderServerNames();
    expect(choiceValues(currentOutboundNameChoices('main'))).toContain(
      'Zurich',
    );
  });

  it('ask the core again for the next dialog', async () => {
    section(['first']);
    await loadProviderServerNames();
    answerWith(
      Promise.resolve(
        clashAnswer({
          providers: {
            'Main/sub1': { proxies: [{ name: 'Main/sub1/Oslo' }] },
          },
        }),
      ),
    );

    forgetOutboundNameChoices();
    currentOutboundNameChoices('main');
    await loadProviderServerNames();
    expect(choiceValues(currentOutboundNameChoices('main')).slice(3)).toEqual([
      'Oslo',
    ]);
  });
});

describe('the draft names of a section', () => {
  function sectionWithDrafts(values: Record<string, string[]>) {
    installLuciStubs({
      main: { '.type': 'section', label: 'Main' },
      saved_interface: {
        '.type': 'section_interface',
        section: 'main',
        name: 'lan1',
        display_name: 'Renamed interface',
      },
      saved_link: {
        '.type': 'connection_link',
        section: 'main',
        uri: 'vless://saved.test#Fragment',
        name: 'Stored name',
      },
    });

    const interfaceOption = {
      sharedPendingSettingsKey: 'interfaces',
      formvalue: () => values.interfaces || [],
    };
    outboundNameSourceOptions.set('interfaces', interfaceOption);
    const linkOption = { formvalue: () => values.connection_link || [] };
    outboundNameSourceOptions.set('connection_link', linkOption);
    outboundNameSourceOptions.set('outbound_jsons', {
      formvalue: () => values.outbound_jsons || [],
    });
    outboundNameSourceOptions.set('tunnels', {
      formvalue: () => values.tunnels || [],
    });

    childPendingSettingsStore(
      interfaceOption as unknown as CBIOption,
      'main',
    ).new_interface = { display_name: 'Draft interface' };

    return values;
  }

  const SOURCES = {
    connection_link: ['saved_link', 'vless://example.test#Draft%20URL'],
    interfaces: ['saved_interface', 'new_interface'],
    outbound_jsons: [
      '{"type":"socks","tag":"Leaf JSON"}',
      '{"type":"fallback","tag":"fallback"}',
      '{"type":"urltest","tag":"urltest"}',
    ],
  };

  it('replace a renamed interface, keep a staged one, and exclude the groups', () => {
    sectionWithDrafts({ ...SOURCES });

    expect(currentDraftOutboundNames('main')).toEqual([
      'Stored name',
      'Draft URL',
      'Renamed interface',
      'Draft interface',
      'Leaf JSON',
    ]);
  });

  it('drop an unsaved URL the moment it is deleted', () => {
    const values = sectionWithDrafts({
      ...SOURCES,
      connection_link: [],
    });
    void values;

    expect(currentDraftOutboundNames('main')).toEqual([
      'Renamed interface',
      'Draft interface',
      'Leaf JSON',
    ]);
  });
});

describe('a name in a section', () => {
  function section() {
    installLuciStubs({
      main: { '.type': 'section', label: 'Main' },
      germany: {
        '.type': 'connection_link',
        section: 'main',
        uri: 'vless://a.test#A',
        name: 'Germany',
      },
      uplink: {
        '.type': 'section_interface',
        section: 'main',
        name: 'wan',
        display_name: 'Uplink',
      },
      fastest: { '.type': 'urltest', section: 'main', name: 'Fastest' },
    });
    const listed = (values: string[]) => ({ formvalue: () => values });
    outboundNameSourceOptions.set('connection_link', listed(['germany']));
    outboundNameSourceOptions.set('interfaces', {
      sharedPendingSettingsKey: 'interfaces',
      ...listed(['uplink']),
    });
    outboundNameSourceOptions.set('tunnels', listed([]));
    outboundNameSourceOptions.set(
      'outbound_jsons',
      listed(['{"type":"socks","tag":"Hop"}']),
    );
    outboundNameSourceOptions.set('urltest', listed(['fastest']));
    outboundNameSourceOptions.set('fallback_group', listed([]));
  }
  const TAKEN = 'Name already taken';

  it('belongs to one server or group of whatever kind', () => {
    section();

    expect(validateSectionChildName('main', 'json', 'Germany')).toBe(TAKEN);
    expect(validateSectionChildName('main', 'link', 'Fastest')).toBe(TAKEN);
    expect(validateSectionChildName('main', 'fallback', 'Hop')).toBe(TAKEN);
    expect(validateSectionChildName('main', 'json', 'Uplink')).toBe(TAKEN);
    expect(validateSectionChildName('main', 'json', 'Netherlands')).toBe(true);
  });

  it('leaves two of one list to the list, and knows an interface by its own name', () => {
    section();

    expect(validateSectionChildName('main', 'link', 'Germany')).toBe(true);
    expect(validateSectionChildName('main', 'interface', 'Uplink', 'wan')).toBe(
      true,
    );
    expect(validateSectionChildName('main', 'interface', 'Uplink', 'lan')).toBe(
      TAKEN,
    );
  });

  it('holds no slash', () => {
    section();

    expect(validateSectionChildName('main', 'link', 'US/LA')).toBe(
      'The / character is not allowed',
    );
  });
});

describe('the name offered to a new group', () => {
  function section(urltests: Record<string, string>, linkName: string) {
    installLuciStubs({
      main: { '.type': 'section', label: 'Main' },
      link: {
        '.type': 'connection_link',
        section: 'main',
        uri: 'vless://a.test#A',
        name: linkName,
      },
      ...Object.fromEntries(
        Object.entries(urltests).map(([id, name]) => [
          id,
          { '.type': 'urltest', section: 'main', name },
        ]),
      ),
    });
    const listed = (values: string[]) => ({ formvalue: () => values });
    outboundNameSourceOptions.set('connection_link', listed(['link']));
    outboundNameSourceOptions.set('interfaces', listed([]));
    outboundNameSourceOptions.set('tunnels', listed([]));
    outboundNameSourceOptions.set('outbound_jsons', listed([]));
    outboundNameSourceOptions.set('urltest', listed(Object.keys(urltests)));
    outboundNameSourceOptions.set('fallback_group', listed([]));
  }

  it('is one past the highest number taken, not one past the count', () => {
    section({ second: 'URLTest #2' }, 'Germany');

    expect(nextSectionChildName('main', 'URLTest')).toBe('URLTest #3');
  });

  it('starts at one among groups the user named', () => {
    section({ fastest: 'test' }, 'Germany');

    expect(nextSectionChildName('main', 'URLTest')).toBe('URLTest #1');
  });

  it('skips a name a server of the section holds, since names are shared', () => {
    section({}, 'Fallback #1');

    expect(nextSectionChildName('main', 'Fallback')).toBe('Fallback #2');
  });
});

describe('outboundNameChoiceItems', () => {
  it('offers a name two servers share once, where it first appears', () => {
    expect(outboundNameChoiceItems(['wan', 'lan2', 'wan'])).toEqual([
      { value: 'wan', label: 'wan' },
      { value: 'lan2', label: 'lan2' },
    ]);
  });
});

describe('currentLiveDynamicListValues', () => {
  it('reads the tracked widget rather than the one the document still has', () => {
    const node = {
      isConnected: true,
      querySelectorAll: () => [],
      querySelector: () => null,
    };
    outboundNameSourceOptions.set('connection_link', {
      liveDynamicListNodes: new Map([['main', node]]),
    });
    (globalThis as unknown as Record<string, unknown>).document = {
      getElementById() {
        throw new Error('the stale duplicate DynamicList was used');
      },
    };

    expect(currentLiveDynamicListValues('main', 'connection_link')).toEqual([]);
  });

  it('answers nothing at all once the tracked widget is unmounted', () => {
    outboundNameSourceOptions.set('connection_link', {
      liveDynamicListNodes: new Map([['main', { isConnected: false }]]),
    });

    expect(currentLiveDynamicListValues('main', 'connection_link')).toBe(null);
  });
});
