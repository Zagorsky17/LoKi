import { expect, test } from 'bun:test';

import { buildLogsWebSocketURL, buildWebSocketURL, getURLAndInit, readErrorMessage } from '../src/misc/request-helper';
import { requestDelayForProxy } from '../src/api/proxies';

const location = { protocol: 'https:', origin: 'https://router.example:9091' };
Object.defineProperty(globalThis, 'window', { configurable: true, value: { location } });

test('ignores saved backends and bearer secrets', () => {
  const { url, init } = getURLAndInit({ baseURL: 'https://attacker.example', secret: 'synthetic-secret' });
  expect(url).toBe('https://router.example:9091/cgi-bin/luci/loki-gateway/api');
  expect(init).toEqual({
    headers: { 'Content-Type': 'application/json', 'X-Loki-CSRF': '1' },
    credentials: 'same-origin',
    cache: 'no-store',
  });
  expect(JSON.stringify(init)).not.toContain('synthetic-secret');
});

test('WebSockets stay on the gateway and never carry bearer tokens', () => {
  const config = { baseURL: 'http://attacker.example', secret: 'synthetic-secret' };
  expect(buildWebSocketURL(config, '/traffic')).toBe(
    'wss://router.example:9091/cgi-bin/luci/loki-gateway/api/traffic',
  );
  expect(buildLogsWebSocketURL({ ...config, logLevel: 'warn&token=synthetic-secret' }, '/logs')).toBe(
    'wss://router.example:9091/cgi-bin/luci/loki-gateway/api/logs?level=warn%26token%3Dsynthetic-secret',
  );
});

test('refuses HTTP pages before creating an API URL', () => {
  location.protocol = 'http:';
  try {
    expect(() => getURLAndInit({ baseURL: 'http://router.example' })).toThrow('YACD requires HTTPS');
    expect(() => buildWebSocketURL({ baseURL: 'http://router.example' }, '/traffic')).toThrow(
      'YACD requires HTTPS',
    );
  } finally {
    location.protocol = 'https:';
  }
});

test('does not expose error bodies that contain connection secrets', async () => {
  const response = new Response('{"message":"synthetic-secret"}', { status: 502 });
  expect(await readErrorMessage(response, 'proxy change')).toBe('Request failed (HTTP 502)');
});

test('latency probes send only the gateway allowlisted query', async () => {
  const originalFetch = globalThis.fetch;
  let requested = '';
  globalThis.fetch = async (input) => {
    requested = String(input);
    return new Response('{"delay":42}', { status: 200 });
  };
  try {
    await requestDelayForProxy({ baseURL: 'https://attacker.example', secret: 'synthetic-secret' }, 'node/one', 'https://example.com/check', 5000);
    expect(requested).toBe('https://router.example:9091/cgi-bin/luci/loki-gateway/api/proxies/node%2Fone/delay?timeout=5000&url=https%3A%2F%2Fexample.com%2Fcheck');
    expect(requested).not.toContain('synthetic-secret');
  } finally {
    globalThis.fetch = originalFetch;
  }
});
