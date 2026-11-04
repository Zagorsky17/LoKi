import { describe, expect, it } from 'vitest';
import { validateDNS } from '../validateDns.js';
import { invalidIPs, validIPs } from './validateIp.test';
import { invalidDomains, validDomains } from './validateDomain.test';

const additionalValidDns = [
  ['Google DNS (port 53)', '8.8.8.8:53'],
  ['Google DNS (port 5353)', '8.8.8.8:5353'],
  ['TCP DNS', 'tcp://8.8.8.8'],
  ['DoT IP', 'tls://1.1.1.1:853'],
  ['DoT domain', 'tls://cloudflare-dns.com'],
  ['DoH IP', 'https://1.1.1.1/dns-query'],
  ['DoH domain with port', 'https://cloudflare-dns.com:443/dns-query'],
  ['DoQ domain', 'quic://dns.adguard-dns.com'],
  ['DoH3 domain', 'h3://dns.google/dns-query'],
  ['IPv6 DNS', '2606:4700:4700::1111'],
  ['IPv6 DNS with port', '[2606:4700:4700::1111]:853'],
  ['IPv6 DoH with port', 'https://[2606:4700:4700::1111]:443/dns-query'],
];

const validDns = [
  ...validIPs,
  ...validDomains.filter(([, value]) => !value.includes('/')),
  ...additionalValidDns,
];

const invalidDns = [
  ...invalidIPs,
  ...invalidDomains,
  ['Non-numeric port', '8.8.8.8:abc'],
  ['Port too high', 'dns.example.com:99999'],
  ['Zero IPv6 port', '[2606:4700:4700::1111]:0'],
  ['Unsupported HTTP', 'http://dns.example.com/dns-query'],
  ['Path without HTTPS', 'dns.example.com/dns-query'],
  ['UDP path', 'udp://8.8.8.8/dns-query'],
  ['Credentials', 'https://user@dns.example.com/dns-query'],
  ['Query parameters', 'https://dns.example.com/dns-query?token=secret'],
  ['Fragment', 'tls://dns.example.com#dns'],
];

describe('validateDns', () => {
  describe.each(validDns)('Valid dns: %s', (_desc, domain) => {
    it(`returns true for "${domain}"`, () => {
      const res = validateDNS(domain);
      expect(res).toBe(true);
    });
  });

  describe.each(invalidDns)('Invalid dns: %s', (_desc, domain) => {
    it(`returns a reason for "${domain}"`, () => {
      const res = validateDNS(domain);
      expect(res).not.toBe(true);
    });
  });

  it('requires an IP address for Bootstrap DNS', () => {
    expect(validateDNS('https://1.1.1.1/dns-query', true)).toBe(true);
    expect(validateDNS('https://dns.example.com/dns-query', true)).toBe(
      'IP address only',
    );
  });
});
