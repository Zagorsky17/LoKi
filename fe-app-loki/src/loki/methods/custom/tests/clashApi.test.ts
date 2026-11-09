import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  config: vi.fn(),
  clashApi: vi.fn(),
}));

vi.mock('../getConfigSections', () => ({ getConfigSections: mocks.config }));
vi.mock('../../shell', () => ({
  LokiShellMethods: { clashApi: mocks.clashApi },
}));
vi.mock('../../../../helpers/getClashApiUrl', () => ({
  canUseDirectClashApi: () => true,
  getClashApiUrl: () =>
    'https://router.example:9091/cgi-bin/luci/loki-gateway/api',
}));

beforeEach(() => {
  vi.resetModules();
  mocks.config.mockResolvedValue([
    { '.type': 'settings', latency_test_url: 'https://example.com/check' },
  ]);
  mocks.clashApi.mockReset();
  mocks.clashApi.mockResolvedValue({
    success: true,
    data: { status: 204, body: '' },
  });
});

afterEach(() => vi.unstubAllGlobals());

it('chooses the CLI before sending concurrent first mutations to an unreachable controller', async () => {
  const fetchMock = vi.fn().mockRejectedValue(new TypeError('Failed to fetch'));
  vi.stubGlobal('fetch', fetchMock);
  const { updateClashApiProxyProviders } = await import('../clashApi');

  expect((await updateClashApiProxyProviders(['one', 'two'])).success).toBe(
    true,
  );
  expect(fetchMock).toHaveBeenCalledOnce();
  expect(fetchMock).toHaveBeenCalledWith(
    'https://router.example:9091/cgi-bin/luci/loki-gateway/api/version',
    expect.anything(),
  );
  expect(mocks.clashApi).toHaveBeenCalledTimes(2);
});

it('asks for the exit of an outbound by its encoded tag', async () => {
  const report = {
    outbound: 'main/sub1/🇳🇱 Node',
    ipv4: { address: '203.0.113.7', country: 'NL' },
    ipv6: { error: 'connection refused' },
  };
  const fetchMock = vi.fn().mockResolvedValue({
    status: 200,
    text: async () => JSON.stringify(report),
  });
  vi.stubGlobal('fetch', fetchMock);
  const { getClashApiProxyExit } = await import('../clashApi');

  expect(await getClashApiProxyExit('main-out/selector')).toEqual({
    success: true,
    data: report,
  });
  expect(fetchMock).toHaveBeenLastCalledWith(
    'https://router.example:9091/cgi-bin/luci/loki-gateway/api/proxies/main-out%2Fselector/exit?timeout=5000',
    expect.anything(),
  );
});

it('loads the configured test URL before the first latency request', async () => {
  const fetchMock = vi
    .fn()
    .mockResolvedValue({ status: 200, text: async () => '{}' });
  vi.stubGlobal('fetch', fetchMock);
  const { getClashApiProxyLatency } = await import('../clashApi');

  await getClashApiProxyLatency('node');
  expect(fetchMock).toHaveBeenLastCalledWith(
    'https://router.example:9091/cgi-bin/luci/loki-gateway/api/proxies/node/delay?url=https%3A%2F%2Fexample.com%2Fcheck&timeout=5000',
    expect.anything(),
  );
});

it('uses only LuCI session credentials and the fixed CSRF marker, never a configured controller bearer', async () => {
  mocks.config.mockResolvedValue([
    { '.type': 'settings', yacd_secret_key: 'synthetic-browser-secret' },
  ]);
  const fetchMock = vi
    .fn()
    .mockResolvedValue({ status: 204, text: async () => '' });
  vi.stubGlobal('fetch', fetchMock);
  const { setClashApiGroupProxy } = await import('../clashApi');
  await setClashApiGroupProxy('Office/OUT', 'Node #1');
  expect(fetchMock).toHaveBeenCalled();
  for (const [url, init] of fetchMock.mock.calls) {
    expect(url).toMatch(
      /^https:\/\/router\.example:9091\/cgi-bin\/luci\/loki-gateway\/api\//,
    );
    expect(init.credentials).toBe('include');
    expect(init.headers).toEqual(
      init.method === 'PUT'
        ? { 'Content-Type': 'application/json', 'X-Loki-CSRF': '1' }
        : { 'X-Loki-CSRF': '1' },
    );
    expect(JSON.stringify([url, init])).not.toContain(
      'synthetic-browser-secret',
    );
  }
});
