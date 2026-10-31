// Modified for LoKi on 2026-10-31: main DNS encryption is selected explicitly.
import { beforeEach, describe, expect, it } from 'vitest';

import { coreFeatures } from '../lib/coreFeatures.js';
import { createHarness } from '../lib/luciForm.js';

const base = () => coreFeatures();
const without = (...tags) => coreFeatures({ remove: tags });
const tiny = () =>
  without(
    'with_gvisor',
    'with_wireguard',
    'with_openvpn',
    'with_trusttunnel',
    'with_vmess',
    'with_anytls',
  );

let harness;

beforeEach(() => {
  harness = createHarness();
});

function addSections(list) {
  list.forEach(([type, sid, values]) => {
    harness.uci.add('forkop', type, sid);
    Object.assign(harness.store.get(sid), values);
  });
  harness.operations.length = 0;
}

function grid(type, build) {
  const map = new harness.form.Map('forkop');
  const section = map.section(harness.form.GridSection, type);
  build(section);
  return section;
}

const option = (section, name) =>
  section.children.find((child) => child.option === name);

describe('the Servers tab', () => {
  it('offers only the protocols the core has', async () => {
    harness.bundle.setCoreFeatures(without('with_quic'));
    addSections([['server', 'srv', { protocol: 'vless' }]]);
    const servers = grid('server', (s) =>
      harness.bundle.createServerContent(s),
    );
    const protocol = option(servers, 'protocol');

    await protocol.load('srv');

    expect(protocol.keylist).toEqual(
      expect.arrayContaining(['mixed', 'vless', 'vmess', 'anytls']),
    );
    for (const missing of ['hysteria2', 'tuic', 'naive', 'tailscale', 'mieru'])
      expect(protocol.keylist).not.toContain(missing);
  });

  it('keeps a stored protocol the core lacks, marked, and refuses it on save', async () => {
    harness.bundle.setCoreFeatures(without('with_quic'));
    addSections([['server', 'srv', { protocol: 'hysteria2' }]]);
    const servers = grid('server', (s) =>
      harness.bundle.createServerContent(s),
    );
    const protocol = option(servers, 'protocol');

    await protocol.load('srv');

    const index = protocol.keylist.indexOf('hysteria2');
    expect(index).toBeGreaterThanOrEqual(0);
    expect(protocol.vallist[index]).toBe(
      'Hysteria2 (the installed sing-box lacks with_quic)',
    );
    expect(protocol.validate('srv', 'hysteria2')).toBe(
      'sing-box is built without with_quic',
    );
    expect(option(servers, '_protocol_display').textvalue('srv')).toBe(
      'Hysteria2 (the installed sing-box lacks with_quic)',
    );
  });

  it('asks for uTLS for Reality and for QUIC for NaiveProxy over UDP', () => {
    harness.bundle.setCoreFeatures(without('with_utls', 'with_quic'));
    addSections([['server', 'srv', { protocol: 'vless' }]]);
    const servers = grid('server', (s) =>
      harness.bundle.createServerContent(s),
    );

    expect(option(servers, 'security').validate('srv', 'reality')).toBe(
      'sing-box is built without with_utls',
    );
    expect(option(servers, 'security').validate('srv', 'tls')).toBe(true);
    expect(option(servers, 'naive_network').validate('srv', 'udp')).toBe(
      'sing-box is built without with_quic',
    );
    expect(option(servers, 'naive_network').validate('srv', 'tcp')).toBe(true);
  });

  it('refuses nothing the base build has', () => {
    harness.bundle.setCoreFeatures(base());
    addSections([['server', 'srv', { protocol: 'vless' }]]);
    const servers = grid('server', (s) =>
      harness.bundle.createServerContent(s),
    );

    expect(option(servers, 'protocol').validate('srv', 'hysteria2')).toBe(true);
    expect(option(servers, 'security').validate('srv', 'reality')).toBe(true);
    expect(option(servers, 'protocol').validate('srv', 'tailscale')).toBe(
      'sing-box is built without with_tailscale',
    );
  });

  it('asks for QUIC for XHTTP over HTTP/3, which TLS offering h3 alone picks', () => {
    harness.bundle.setCoreFeatures(without('with_quic'));
    addSections([
      [
        'server',
        'srv',
        {
          protocol: 'vless',
          security: 'tls',
          transport: 'xhttp',
          tls_alpn: ['h3'],
        },
      ],
    ]);
    const servers = grid('server', (s) =>
      harness.bundle.createServerContent(s),
    );

    expect(option(servers, 'transport').validate('srv', 'xhttp')).toBe(
      'sing-box is built without with_quic',
    );
    expect(option(servers, '_protocol_display').textvalue('srv')).toBe(
      'VLESS (the installed sing-box lacks with_quic)',
    );
    expect(option(servers, 'transport').validate('srv', 'ws')).toBe(true);

    harness.store.get('srv').tls_alpn = ['h3', 'h2'];
    expect(option(servers, 'transport').validate('srv', 'xhttp')).toBe(true);
    expect(option(servers, '_protocol_display').textvalue('srv')).toBe('VLESS');
  });
});

describe('the Sections tab', () => {
  function sections() {
    return grid('section', (s) => {
      harness.bundle.configureSectionSection(s, {
        loadActionProvidersAvailability: () =>
          Promise.resolve({
            zapretInstalled: false,
            zapret2Installed: false,
            byedpiInstalled: false,
          }),
      });
      delete s.load;
      harness.bundle.createSectionContent(s);
    });
  }

  it('lists and takes only the links the core can dial', () => {
    harness.bundle.setCoreFeatures(base());
    const links = option(sections(), 'connection_link');

    expect(links.description).toBe(
      'Supported URIs: vless, vmess, shadowsocks, trojan, socks, http, tuic, hysteria, anytls, trusttunnel',
    );
    expect(links.validate('sec', 'http://u:p@example.com:8080#h')).toBe(true);
    expect(links.validate('sec', 'naive+https://u:p@example.com:443#n')).toBe(
      'sing-box is built without with_naive',
    );
    expect(
      links.validate(
        'sec',
        'mierus://u:p@example.com?profile=p&port=443&protocol=TCP#m',
      ),
    ).toBe('sing-box is built without with_mieru');
    expect(links.validate('sec', 'hy2://p@example.com:443#h')).toBe(true);
  });

  it('names only the tunnel kinds the core has', () => {
    harness.bundle.setCoreFeatures(base());
    expect(option(sections(), 'tunnels').description).toBe(
      'Available: WireGuard, AmneziaWG, Cloudflare WARP, OpenVPN, JSON endpoint',
    );

    harness.bundle.setCoreFeatures(coreFeatures({ add: ['with_tailscale'] }));
    expect(option(sections(), 'tunnels').description).toBe(
      'Available: WireGuard, AmneziaWG, Cloudflare WARP, Tailscale, OpenVPN, JSON endpoint',
    );
  });

  it('marks a section whose tunnel the core lacks', () => {
    harness.bundle.setCoreFeatures(without('with_wireguard'));
    addSections([
      ['section', 'sec', { action: 'connection', enabled: '1', label: 'Home' }],
      ['tunnel', 'tun', { section: 'sec', kind: 'wireguard', name: 'WG' }],
    ]);

    expect(option(sections(), '_action_display').cfgvalue('sec')).toBe(
      'Connection (the installed sing-box lacks with_wireguard)',
    );
  });

  it('offers a new tunnel only the kinds the core has', async () => {
    harness.bundle.setCoreFeatures(without('with_wireguard'));
    addSections([
      ['section', 'sec', { action: 'connection', enabled: '1', label: 'Home' }],
    ]);
    const dialog = await harness.openDialog(
      option(sections(), 'tunnels'),
      'sec',
      '',
      { adding: true },
    );
    const kind = option(dialog.map.children[0], 'tunnel_type');

    expect(kind.keylist).toEqual(['openvpn-client', 'json']);
    expect(await kind.load('settings')).toBe('openvpn-client');
  });

  async function loadedTunnels(sectionId) {
    const s = sections();
    option(s, 'action').cfgvalue(sectionId, 'connection');
    const tunnels = option(s, 'tunnels');
    tunnels.cfgvalue(sectionId, await tunnels.load(sectionId));
    return tunnels;
  }

  it('shows the Tunnel field only while the core runs a tunnel or the section has one', async () => {
    harness.bundle.setCoreFeatures(base());
    addSections([
      ['section', 'sec', { action: 'connection', enabled: '1', label: 'Home' }],
    ]);
    let tunnels = await loadedTunnels('sec');
    expect(tunnels.checkDepends('sec')).toBe(true);
    expect(tunnels.addable('sec')).toBe(true);

    harness.bundle.setCoreFeatures(tiny());
    tunnels = await loadedTunnels('sec');
    expect(tunnels.checkDepends('sec')).toBe(false);
    expect(tunnels.description).toBe('');

    addSections([
      ['tunnel', 'tun', { section: 'sec', kind: 'wireguard', name: 'WG' }],
    ]);
    tunnels = await loadedTunnels('sec');
    expect(tunnels.checkDepends('sec')).toBe(true);
    expect(tunnels.addable('sec')).toBe(false);
  });

  it('offers a JSON endpoint only with a core that builds an endpoint', () => {
    harness.bundle.setCoreFeatures(
      coreFeatures({
        remove: ['with_wireguard', 'with_openvpn'],
        add: ['with_tailscale'],
      }),
    );
    expect(option(sections(), 'tunnels').description).toBe(
      'Available: Tailscale, JSON endpoint',
    );
  });

  it('judges a saved JSON endpoint by the type it declares', async () => {
    harness.bundle.setCoreFeatures(tiny());
    addSections([
      ['section', 'sec', { action: 'connection', enabled: '1', label: 'Home' }],
      [
        'tunnel',
        'tun',
        {
          section: 'sec',
          kind: 'json',
          endpoint_json: '{"type":"wireguard","tag":"raw"}',
        },
      ],
    ]);

    expect(option(sections(), '_action_display').cfgvalue('sec')).toBe(
      'Connection (the installed sing-box lacks with_wireguard, with_gvisor)',
    );
    expect(option(sections(), 'tunnels').validate('sec', 'tun')).toBe(
      'raw: sing-box is built without with_wireguard, with_gvisor',
    );
    const dialog = await harness.openDialog(
      option(sections(), 'tunnels'),
      'sec',
      'tun',
    );
    const kind = option(dialog.map.children[0], 'tunnel_type');
    expect(kind.keylist).toEqual(['json']);
    expect(kind.vallist).toEqual([
      'JSON endpoint (the installed sing-box lacks with_wireguard, with_gvisor)',
    ]);

    harness.bundle.setCoreFeatures(base());
    expect(option(sections(), 'tunnels').validate('sec', 'tun')).toBe(true);
  });
});

describe('the Settings tab', () => {
  function settings() {
    const map = new harness.form.Map('forkop');
    const section = map.section(harness.form.TypedSection, 'settings');
    section.cfgsections = () => ['settings'];
    harness.bundle.createSettingsContent(section);
    return section;
  }

  it('offers WARP profile requests through a section only with WARP, or while they are on', () => {
    harness.bundle.setCoreFeatures(without('with_wireguard'));
    addSections([['settings', 'settings', {}]]);
    let flag = option(settings(), 'warp_profiles_via_proxy');
    flag.cfgvalue('settings', '0');
    expect(flag.checkDepends('settings')).toBe(false);

    flag.cfgvalue('settings', '1');
    expect(flag.checkDepends('settings')).toBe(true);
    expect(flag.validate('settings', '1')).toBe(
      'sing-box is built without with_wireguard',
    );
    expect(flag.validate('settings', '0')).toBe(true);

    harness.bundle.setCoreFeatures(base());
    flag = option(settings(), 'warp_profiles_via_proxy');
    flag.cfgvalue('settings', '0');
    expect(flag.checkDepends('settings')).toBe(true);
    expect(flag.validate('settings', '1')).toBe(true);
  });

  it('keeps the selected DoT protocol regardless of QUIC support', () => {
    addSections([['settings', 'settings', {}]]);
    for (const features of [without('with_quic'), base()]) {
      harness.bundle.setCoreFeatures(features);
      const section = settings();
      option(section, 'dns_encryption').cfgvalue('settings', '1');
      option(section, 'dns_encrypted_protocol').cfgvalue('settings', 'tls');
      const dns = option(section, 'dns_server');
      expect(dns.validate('settings', 'tls://192.0.2.53')).toBe(true);
      expect(dns.validate('settings', 'quic://dns.example.com')).not.toBe(true);
      expect(dns.validate('settings', 'h3://192.0.2.53/dns-query')).not.toBe(
        true,
      );
      expect(
        dns.validate('settings', 'https://dns.example/dns-query'),
      ).not.toBe(true);
    }
  });
});
