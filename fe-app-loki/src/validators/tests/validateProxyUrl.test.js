import { describe, it, expect } from 'vitest';
import { validateProxyUrl } from '../validateProxyUrl';

const validUrls = [
  ['shadowsocks', 'ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388'],
  [
    'vless',
    'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com:443?type=tcp&encryption=none&security=none',
  ],
  [
    'vmess',
    `vmess://${Buffer.from(
      JSON.stringify({
        v: '2',
        ps: 'Example VMess',
        add: 'example.com',
        port: '443',
        id: '94792286-7bbe-4f33-8b36-18d1bbf70723',
        aid: '0',
        scy: 'auto',
        net: 'ws',
        type: 'none',
        host: 'example.com',
        path: '/ws',
        tls: 'tls',
        sni: 'example.com',
      }),
    ).toString('base64')}`,
  ],
  ['trojan', 'trojan://password@example.com:443'],
  ['socks', 'socks://127.0.0.1:1080'],
  ['socks4', 'socks4://127.0.0.1:1080'],
  ['socks4a', 'socks4a://example.com:1080'],
  ['socks5', 'socks5://user:pass@example.com:1080'],
  ['HTTP proxy', 'http://user:password@example.com:8080'],
  ['HTTPS proxy on its port', 'https://example.com:443'],
  ['HTTP proxy named with a slash', 'http://example.com:3128#RU/Moscow'],
  ['HTTPS proxy with credentials only', 'https://user:password@example.com'],
  ['tuic', 'tuic://uuid:password@example.com:443'],
  [
    'tt',
    'tt://?AAECAQ92cG4uZXhhbXBsZS5jb20FBWFsaWNlBglzZWNyZXQxMjMCCzEuMi4zLjQ6NDQz',
  ],
  ['hysteria', 'hysteria://example.com:443?auth=secret'],
  ['hysteria2', 'hysteria2://password@example.com:443'],
  ['hy2', 'hy2://password@example.com:443'],
  [
    'Shadowrocket Naive HTTP2',
    'http2://dXNlcjpwYXNzd29yZEBleGFtcGxlLmNvbTo0NDM=',
  ],
  [
    'Shadowrocket Naive HTTP3',
    'http3://dXNlcjpwYXNzd29yZEBleGFtcGxlLmNvbTo0NDM=',
  ],
  ['naive HTTPS', 'naive+https://user:password@example.com:443'],
  ['naive QUIC', 'naive+quic://user:password@example.com:443'],
  ['anytls', 'anytls://password@example.com:8443?sni=example.com&insecure=1'],
  [
    'mieru simple',
    'mierus://user:password@example.com?profile=default&port=443&protocol=TCP',
  ],
  ['mieru standard', 'mieru://opaque-native-payload'],
  [
    'mKCP transport delegated to core',
    'vless://uuid@example.com:443?type=kcp&headerType=wechat-video&seed=secret',
  ],
];

describe('validateProxyUrl', () => {
  describe.each(validUrls)('Valid proxy URL: %s', (_desc, url) => {
    it(`returns true for "${url}"`, () => {
      const res = validateProxyUrl(url);
      expect(res).toBe(true);
    });
  });

  it('trims surrounding whitespace before dispatching', () => {
    const res = validateProxyUrl('  socks5://user:pass@example.com:1080  ');

    expect(res).toBe(true);
  });

  it('returns a clear error for unsupported protocols', () => {
    const res = validateProxyUrl('wireguard://example.com');

    expect(res).toBe('Unsupported link');
  });

  it.each([
    'https://sub.example.com/api/sub/token',
    'https://panel.example.com:2096/sub/abc#Mine',
    'https://example.com/api/v1/client/subscribe?token=abc',
    'https://example.com',
  ])('sends the subscription address %s to its own field', (url) => {
    expect(validateProxyUrl(url)).toBe(
      'Probably a subscription URL: paste it into Subscription',
    );
  });

  it('leaves protocol-specific validation to loki-core', () => {
    expect(validateProxyUrl('vmess://opaque-native-payload')).toBe(true);
  });

  it('rejects whitespace and empty payloads before they reach the core', () => {
    expect(validateProxyUrl('vless://')).not.toBe(true);
    expect(validateProxyUrl('vless://#name')).not.toBe(true);
    expect(validateProxyUrl('vless://uuid @example.com:443')).not.toBe(true);
    expect(
      validateProxyUrl('vless://uuid@example.com:443?path=/a b#name'),
    ).not.toBe(true);
    expect(validateProxyUrl('vless://uuid@example.com:443#a\tb')).not.toBe(
      true,
    );
  });

  it.each([
    'vless://uuid@example.com:443?security=none#My Server',
    'trojan://password@[2001:db8::1]:443#🇩🇪 Germany 1',
    'ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#a  b ',
  ])('takes a name with spaces, as the core does: %s', (url) => {
    expect(validateProxyUrl(url)).toBe(true);
  });
});
