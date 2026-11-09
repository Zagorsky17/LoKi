import { describe, expect, it } from 'vitest';

import { getProxyUrlName } from '../getProxyUrlName';

describe('getProxyUrlName', () => {
  it('matches sing-box link tag parsing', () => {
    expect(getProxyUrlName('vless://id@example.com#Node+Plus')).toBe(
      'Node+Plus',
    );
    expect(getProxyUrlName('mierus://user@example.com#Mieru%20Node')).toBe(
      'Mieru Node',
    );
    expect(
      getProxyUrlName(
        `vmess://${btoa(JSON.stringify({ ps: 'VMess node', add: 'example.com' }))}`,
      ),
    ).toBe('VMess node');
    expect(
      getProxyUrlName(
        'vmess://{"ps":"Raw VMess","add":"example.com","path":"/ws?ed=2048#inside"}',
      ),
    ).toBe('Raw VMess');
    expect(getProxyUrlName('trojan://secret@example.com')).toBe('');
  });

  it.each([
    ['vmess://uuid@host:443?type=tcp#My%20Node', 'My Node'],
    ['vless://id@h#a#b', 'a#b'],
    ['vless://id@h#100%25', '100%'],
    ['vless://id@h#50%off', '50%off'],
    ['vless://id@h#%D0%A3%D0%B7%D0%B5%D0%BB', 'Узел'],
    [
      `vmess://${btoa(JSON.stringify({ ps: '', add: 'example.com' }))}#Fragment`,
      'Fragment',
    ],
  ])('names %s the way the backend does', (link, name) => {
    expect(getProxyUrlName(link)).toBe(name);
  });

  // The links come from TrustTunnel's own encoder, scripts/config_to_deeplink.py.
  it.each([
    [
      'tt://?AAECAQ92cG4uZXhhbXBsZS5jb20FBWFsaWNlBglzZWNyZXQxMjMCCzEuMi4zLjQ6NDQzDArQntGE0LjRgSAx',
      'Офис 1',
    ],
    [
      'tt://?AAECAQ92cG4uZXhhbXBsZS5jb20FBWFsaWNlBglzZWNyZXQxMjMCCzEuMi4zLjQ6NDQzDArQntGE0LjRgSAx#Mine',
      'Mine',
    ],
    [
      'tt://?AAECAQ92cG4uZXhhbXBsZS5jb20FBWFsaWNlBglzZWNyZXQxMjMCCzEuMi4zLjQ6NDQz',
      '',
    ],
    ['tt://?AAECAQ92cG4uZXhh', ''],
    ['tt://?not base64!', ''],
  ])('names the TrustTunnel link %s by its payload', (link, name) => {
    expect(getProxyUrlName(link)).toBe(name);
  });
});
