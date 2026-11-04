// Modified for LoKi on 2026-10-31: main DNS encryption is selected explicitly.
import { beforeEach, describe, expect, it } from 'vitest';

import { coreFeatures } from '../lib/coreFeatures.js';
import { createHarness } from '../lib/luciForm.js';

const base = () => coreFeatures();
const without = (...tags) => coreFeatures({ remove: tags });
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

function grid(type, build) {
  const map = new harness.form.Map('loki');
  const section = map.section(harness.form.GridSection, type);
  build(section);
  return section;
}

const option = (section, name) =>
  section.children.find((child) => child.option === name);

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
});

describe('the Settings tab', () => {
  function settings() {
    const map = new harness.form.Map('loki');
    const section = map.section(harness.form.TypedSection, 'settings');
    section.cfgsections = () => ['settings'];
    harness.bundle.createSettingsContent(section);
    return section;
  }

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
