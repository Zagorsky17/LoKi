import { describe, expect, it } from 'vitest';
import { isCopyableProxyLink } from '../isCopyableProxyLink';

const copyableLinks = [
  'vless://uuid@example.com:443',
  'vmess://encoded',
  'trojan://password@example.com:443',
  'ss://encoded@example.com:443',
  'hysteria://password@example.com:443',
  'hysteria2://password@example.com:443',
  'hy2://password@example.com:443',
  'tuic://uuid:password@example.com:443',
  'socks://example.com:1080',
  'socks4://example.com:1080',
  'socks4a://example.com:1080',
  'socks5://user:pass@example.com:1080',
  'http://example.com:80',
  'https://user:pass@example.com:443',
  'anytls://password@example.com:443',
  'naive+https://user:pass@example.com:443',
  'mieru://example.com:443',
  'tt://?AAECAQ92cG4uZXhhbXBsZS5jb20FBWFsaWNlBglzZWNyZXQxMjMCCzEuMi4zLjQ6NDQz',
];

const nonCopyableLinks = [
  '',
  'direct',
  'block',
  'urltest',
  'wireguard://example.com',
  'ssr://encoded',
];

describe('isCopyableProxyLink', () => {
  describe.each(copyableLinks)('copyable proxy URI %s', (link) => {
    it('returns true', () => {
      expect(isCopyableProxyLink(link)).toBe(true);
    });
  });

  describe.each(nonCopyableLinks)('non-copyable value %s', (link) => {
    it('returns false', () => {
      expect(isCopyableProxyLink(link)).toBe(false);
    });
  });
});
