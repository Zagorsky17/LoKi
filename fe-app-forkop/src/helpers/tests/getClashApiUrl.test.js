import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  canUseDirectClashApi,
  getClashSocketUrl,
  getClashUILoginUrl,
} from '../getClashApiUrl';

beforeEach(() => vi.stubGlobal('L', { hasViewPermission: () => true }));
afterEach(() => vi.unstubAllGlobals());

describe('canUseDirectClashApi', () => {
  it('keeps a reader on the authorized RPC polling path even over HTTP', () => {
    vi.stubGlobal('L', { hasViewPermission: () => false });
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'http:' },
    });
    expect(canUseDirectClashApi()).toBe(false);
  });

  it('does not assume writer access when the permission API is unavailable', () => {
    vi.stubGlobal('L', undefined);
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'http:' },
    });
    expect(canUseDirectClashApi()).toBe(false);
  });

  it('allows direct Clash API access from HTTP LuCI', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'http:' },
    });

    expect(canUseDirectClashApi()).toBe(true);
  });

  it('blocks direct Clash API access from HTTPS LuCI', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'https:' },
    });

    expect(canUseDirectClashApi()).toBe(false);
  });

  it('blocks direct Clash API access outside a browser location', () => {
    vi.stubGlobal('window', undefined);

    expect(canUseDirectClashApi()).toBe(false);
  });
});

describe('getClashSocketUrl', () => {
  it('carries the secret as one query value', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'http:' },
    });

    expect(getClashSocketUrl('/traffic', 'a&b #c+d%')).toBe(
      'ws://router.example:9090/traffic?token=a%26b%20%23c%2Bd%25',
    );
  });
});

describe('getClashUILoginUrl', () => {
  it('hands YACD the backend of the page and the key', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'https:' },
    });

    const [address, query] = getClashUILoginUrl('a&b #c+d=').split('?');
    expect(address).toBe('http://router.example:9090/ui/');
    // As YACD's parseConfigQueryString reads it.
    const values = Object.fromEntries(
      query.split('&').map((pair) => {
        const [key, value] = pair.split('=');
        return [key, decodeURIComponent(value)];
      }),
    );
    expect(values).toEqual({
      hostname: 'router.example',
      port: '9090',
      secret: 'a&b #c+d=',
    });
  });
});
