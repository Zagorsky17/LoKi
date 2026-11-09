import { beforeAll, describe, expect, it } from 'vitest';

import { createHarness } from '../lib/luciForm.js';

const SNAPSHOT = {
  settings: {
    '.type': 'settings',
    dns_server: ['tls://77.88.8.8'],
    bootstrap_dns_server: ['77.88.8.8'],
    config_path: '/etc/loki-core/config.json',
    cache_path: '/tmp/loki-core/cache.db',
    log_level: 'warn',
    latency_test_url: 'https://www.gstatic.com/generate_204',
    source_network_interfaces: ['br-lan'],
  },
  block_rule: {
    '.type': 'section',
    enabled: '1',
    action: 'block',
    label: 'Block',
    community_lists: ['ads'],
  },
  bypass_rule: {
    '.type': 'section',
    enabled: '1',
    action: 'bypass',
    label: 'Bypass',
    destinations: 'example.com',
  },
  dns_rule: {
    '.type': 'section',
    enabled: '1',
    action: 'dns',
    label: 'DNS',
    dns_server: 'tls://1.1.1.1',
  },
  proxy_rule: {
    '.type': 'section',
    enabled: '1',
    action: 'connection',
    label: 'Proxy',
    routing_mode: 'rules',
  },
  link_a1b2c3: {
    '.type': 'connection_link',
    section: 'proxy_rule',
    uri: 'vless://11111111-1111-4111-8111-111111111111@example.com:443?type=tcp&security=tls#node',
    name: 'node',
    order: '0',
  },
  tun_a1b2c3: {
    '.type': 'tunnel',
    section: 'proxy_rule',
    kind: 'wireguard',
    name: 'wg',
    private_key: 'wIWKZmAoiFsYIPFCwG8FRPHKn0P6PLh0hbBjPfKgpU0=',
    address: ['10.8.0.2/32'],
    mtu: '1420',
    order: '0',
  },
  peer_a1b2c3: {
    '.type': 'tunnel_peer',
    tunnel: 'tun_a1b2c3',
    address: 'example.com',
    port: '51820',
    public_key: 'SSw7I859PPdN4DQ7fxV9fobXM61Ms3mqZRlIY1aJvHQ=',
    allowed_ips: ['0.0.0.0/0'],
    order: '0',
  },
  urltest_a1b2c3: {
    '.type': 'urltest',
    section: 'proxy_rule',
    name: 'URLTest',
    check_interval: '3m',
    tolerance: '50',
    testing_url: 'https://www.gstatic.com/generate_204',
    expected_status: '*',
    server_filter_mode: 'all',
  },
  group_a1b2c3: {
    '.type': 'fallback_group',
    section: 'proxy_rule',
    name: 'Fallback',
    health_check_url: 'https://www.gstatic.com/generate_204',
    health_check_interval: '5m',
    health_check_timeout: '5s',
    max_failed_times: '5',
    expected_status: '*',
    idle_timeout: '5m',
  },
  level_a1b2c3: {
    '.type': 'fallback_level',
    group: 'group_a1b2c3',
    name: 'Group #1',
    order: '0',
    server_filter_mode: 'direct',
  },
  sub_a1b2c3: {
    '.type': 'subscription_url',
    section: 'proxy_rule',
    url: 'https://example.com/sub',
    tag: 'sub1',
    server_filter_mode: 'all',
    subscription_update_enabled: '1',
    subscription_update_interval: '1h',
  },
  server_a1b2c3: {
    '.type': 'server',
    label: 'Server #1',
    enabled: '1',
    protocol: 'mixed',
    listen: '0.0.0.0',
    listen_port: '30000',
    public_host: '192.168.1.1',
    security: 'none',
    mixed_auth_enabled: '1',
    routing_mode: 'rules',
  },
  client_a1b2c3: {
    '.type': 'server_client',
    server: 'server_a1b2c3',
    name: 'client-1',
    password: 'Ux-2LP-vrTXCc1wxJt5QUUvK',
  },
};

const EXPECTED_TABS = [
  'section',
  'settings',
  'diagnostic',
  'dashboard',
  'monitoring',
  'logs',
  'components',
];

describe('the shipped page', () => {
  let harness;
  let rendered;

  beforeAll(async () => {
    harness = createHarness();
    for (const [sid, section] of Object.entries(SNAPSHOT)) {
      harness.uci.add('loki', section['.type'], sid);
      const target = harness.store.get(sid);
      for (const [key, value] of Object.entries(section)) {
        if (key.startsWith('.')) continue;
        target[key] = Array.isArray(value) ? value.slice() : value;
      }
    }
    harness.operations.length = 0;

    expect(Object.keys(harness.bundle)).not.toContain('createServerContent');
    expect(Object.keys(harness.bundle)).not.toContain('configureServerSection');
    const view = harness.bundle.LokiView;
    expect(
      typeof view?.render,
      'the bundle must export a renderable LokiView',
    ).toBe('function');
    rendered = await view.render();
  });

  it('renders', () => {
    expect(rendered).toBeTruthy();
  });

  it('writes nothing', () => {
    expect(harness.operations).toEqual([]);
  });

  it('declares every tab, in order', () => {
    expect(harness.form.Map.declaredSectionTypes).toEqual(EXPECTED_TABS);
  });
});

it('renders the viewer monitoring tabs without reading the credential-bearing UCI package', async () => {
  const viewer = createHarness('loki', { writable: false });
  viewer.uci.load = () => {
    throw new Error('raw UCI must not be loaded');
  };
  expect(await viewer.bundle.LokiView.render()).toBeTruthy();
  expect(viewer.form.Map.declaredSectionTypes).toEqual([
    'diagnostic',
    'dashboard',
    'monitoring',
    'logs',
    'components',
  ]);
  expect(viewer.operations).toEqual([]);
});
