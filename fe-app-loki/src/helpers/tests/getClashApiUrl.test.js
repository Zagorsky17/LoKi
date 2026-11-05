import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import * as gateway from '../getClashApiUrl';

beforeEach(() => vi.stubGlobal('L', { hasViewPermission: () => true }));
afterEach(() => vi.unstubAllGlobals());

describe('canUseDirectClashApi', () => {
  it.each(['http:', 'https:'])(
    'keeps a reader on authorized RPC polling over %s',
    (protocol) => {
      vi.stubGlobal('L', { hasViewPermission: () => false });
      vi.stubGlobal('window', {
        location: { hostname: 'router.example', protocol },
      });
      expect(gateway.canUseDirectClashApi()).toBe(false);
    },
  );

  it('does not assume writer access when the permission API is unavailable', () => {
    vi.stubGlobal('L', undefined);
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'https:' },
    });
    expect(gateway.canUseDirectClashApi()).toBe(false);
  });

  it('allows a writer to use the session gateway from HTTPS LuCI', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'https:' },
    });
    expect(gateway.canUseDirectClashApi()).toBe(true);
  });

  it.each(['http:', 'file:', 'https', undefined])(
    'does not create a plaintext or uncertain direct transport over %s',
    (protocol) => {
      vi.stubGlobal('window', {
        location: { hostname: 'router.example', protocol },
      });
      expect(gateway.canUseDirectClashApi()).toBe(false);
    },
  );

  it('blocks direct access without a browser hostname', () => {
    vi.stubGlobal('window', undefined);
    expect(gateway.canUseDirectClashApi()).toBe(false);
    vi.stubGlobal('window', { location: { hostname: '', protocol: 'https:' } });
    expect(gateway.canUseDirectClashApi()).toBe(false);
  });
});

describe('gateway addresses', () => {
  it.each(['router.example', '192.0.2.1', '[2001:db8::1]'])(
    'keeps %s on the fixed HTTPS/WSS path without credentials',
    (hostname) => {
      vi.stubGlobal('window', {
        location: {
          hostname,
          protocol: 'https:',
          search: '?token=page-canary',
          hash: '#private-canary',
        },
      });
      const api = `https://${hostname}:9091/cgi-bin/luci/loki-gateway/api`;
      expect(gateway.getClashApiUrl()).toBe(api);
      expect(gateway.getClashWsUrl()).toBe(api.replace('https:', 'wss:'));
      expect(gateway.getClashSocketUrl('/traffic')).toBe(
        `${api.replace('https:', 'wss:')}/traffic`,
      );
      expect(gateway.getClashSocketUrl('/connections?interval=1000')).toBe(
        `${api.replace('https:', 'wss:')}/connections?interval=1000`,
      );
      expect(gateway.getClashUIUrl()).toBe(
        `https://${hostname}:9091/cgi-bin/luci/loki-gateway/`,
      );
      expect(gateway.getClashUILoginUrl).toBeUndefined();
    },
  );
});
