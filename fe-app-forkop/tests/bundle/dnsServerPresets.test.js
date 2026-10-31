// Modified for LoKi on 2026-10-31: explicit encryption selection must not infer or downgrade protocols.
import { beforeEach, describe, expect, it } from 'vitest';

import { createHarness } from '../lib/luciForm.js';

let harness;

beforeEach(() => {
  harness = createHarness();
  harness.uci.add('forkop', 'settings', 'settings');
});

function settingsOption(name) {
  const map = new harness.form.Map('forkop');
  const section = map.section(harness.form.TypedSection, 'settings');
  section.cfgsections = () => ['settings'];
  harness.bundle.createSettingsContent(section);
  for (const child of section.children)
    child.cfgvalue(
      'settings',
      harness.uci.get('forkop', 'settings', child.ucioption || child.option),
    );
  return section.children.find((child) => child.option === name);
}

describe('the DNS server fields', () => {
  it('offer each public resolver over UDP and DoH as a main server', () => {
    const dns = settingsOption('dns_server');

    expect(dns.keylist).toEqual([
      '77.88.8.8',
      'https://77.88.8.8/dns-query',
      '1.1.1.1',
      'https://1.1.1.1/dns-query',
      '8.8.8.8',
      'https://8.8.8.8/dns-query',
      '9.9.9.9',
      'https://9.9.9.9/dns-query',
      '94.140.14.14',
      'https://94.140.14.14/dns-query',
    ]);
    expect(dns.vallist.slice(0, 2)).toEqual([
      '77.88.8.8 (Yandex)',
      'https://77.88.8.8/dns-query (Yandex)',
    ]);
  });

  it('offer only unfiltered resolvers over UDP as a bootstrap server', () => {
    const bootstrap = settingsOption('bootstrap_dns_server');

    expect(bootstrap.keylist).toEqual([
      '77.88.8.8',
      '1.1.1.1',
      '8.8.8.8',
      '9.9.9.9',
    ]);
    expect(bootstrap.vallist).toEqual([
      '77.88.8.8 (Yandex)',
      '1.1.1.1 (Cloudflare)',
      '8.8.8.8 (Google)',
      '9.9.9.9 (Quad9)',
    ]);
  });

  it('accept every resolver they offer', () => {
    for (const name of ['dns_server', 'bootstrap_dns_server']) {
      const option = settingsOption(name);
      for (const value of option.keylist) {
        const encryption = option.map.lookupOption(
          'dns_encryption',
          'settings',
        )[0];
        const protocol = option.map.lookupOption(
          'dns_encrypted_protocol',
          'settings',
        )[0];
        encryption.cfgvalue(
          'settings',
          value.startsWith('https://') ? '1' : '0',
        );
        protocol.cfgvalue('settings', 'https');
        expect(option.validate('settings', value)).toBe(true);
      }
    }
  });
});

describe('explicit global DNS encryption', () => {
  it('saves explicit choices and keeps the chosen encrypted protocol while disabled', async () => {
    const encryption = settingsOption('dns_encryption');
    const protocol = encryption.map.lookupOption(
      'dns_encrypted_protocol',
      'settings',
    )[0];
    encryption.widgetValue = () => '1';
    protocol.widgetValue = () => 'tls';
    await encryption.parse('settings');
    await protocol.parse('settings');
    expect(harness.uci.get('forkop', 'settings', 'dns_encryption')).toBe('1');
    expect(
      harness.uci.get('forkop', 'settings', 'dns_encrypted_protocol'),
    ).toBe('tls');
    const disabled = settingsOption('dns_encryption');
    disabled.widgetValue = () => '0';
    await disabled.parse('settings');
    await disabled.map
      .lookupOption('dns_encrypted_protocol', 'settings')[0]
      .parse('settings');
    expect(harness.uci.get('forkop', 'settings', 'dns_encryption')).toBe('0');
    expect(
      harness.uci.get('forkop', 'settings', 'dns_encrypted_protocol'),
    ).toBe('tls');
  });

  it('requires a choice for legacy settings instead of inferring one from a URI', () => {
    harness.uci.set('forkop', 'settings', 'dns_server', [
      'https://dns.example/dns-query',
    ]);
    const encryption = settingsOption('dns_encryption');
    expect(encryption).toBeDefined();
    expect(encryption.formvalue('settings')).toBe('');
    expect(encryption.validate('settings', '')).not.toBe(true);
    expect(harness.uci.get('forkop', 'settings', 'dns_server')).toEqual([
      'https://dns.example/dns-query',
    ]);
  });

  it('offers only explicit DoH and DoT choices and retains the saved choice while disabled', () => {
    const protocol = settingsOption('dns_encrypted_protocol');
    expect(protocol.keylist).toEqual(['', 'https', 'tls']);
    expect(protocol.formvalue('settings')).toBe('');
    expect(protocol.retain).toBe(true);
    expect(protocol.validate('settings', '')).not.toBe(true);
  });

  it.each([
    ['0', '', '192.0.2.53', true],
    ['0', '', 'https://dns.example/dns-query', false],
    ['1', 'https', 'https://dns.example/custom-query', true],
    ['1', 'https', '192.0.2.53', false],
    ['1', 'tls', 'tls://dns.example', true],
    ['1', 'tls', 'https://dns.example/dns-query', false],
    ['1', '', 'https://dns.example/dns-query', false],
    ['1', 'udp', '192.0.2.53', false],
    ['1', 'https', 'http://dns.example/dns-query', false],
    [
      '1',
      'https',
      'https://user:synthetic-password@dns.example/dns-query',
      false,
    ],
  ])('mode %s/%s accepts %s: %s', (enabled, protocol, value, accepted) => {
    const dns = settingsOption('dns_server');
    dns.map
      .lookupOption('dns_encryption', 'settings')[0]
      .cfgvalue('settings', enabled);
    dns.map
      .lookupOption('dns_encrypted_protocol', 'settings')[0]
      .cfgvalue('settings', protocol);
    expect(dns.validate('settings', value) === true).toBe(accepted);
  });

  it('refuses encrypted bootstrap and hostnames', () => {
    const bootstrap = settingsOption('bootstrap_dns_server');
    expect(bootstrap.validate('settings', '192.0.2.53')).toBe(true);
    expect(bootstrap.validate('settings', 'tls://192.0.2.53')).not.toBe(true);
    expect(bootstrap.validate('settings', 'bootstrap.example')).not.toBe(true);
  });
});
