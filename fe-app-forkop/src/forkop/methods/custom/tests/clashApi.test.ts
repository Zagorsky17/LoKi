import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  config: vi.fn(),
  clashApi: vi.fn(),
}));

vi.mock('../getConfigSections', () => ({ getConfigSections: mocks.config }));
vi.mock('../../shell', () => ({
  ForkopShellMethods: { clashApi: mocks.clashApi },
}));
vi.mock('../../../../helpers/getClashApiUrl', () => ({
  canUseDirectClashApi: () => true,
  getClashApiUrl: () => 'http://router.example:9090',
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
    'http://router.example:9090/version',
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
    'http://router.example:9090/proxies/main-out%2Fselector/exit?timeout=5000',
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
    'http://router.example:9090/proxies/node/delay?url=https%3A%2F%2Fexample.com%2Fcheck&timeout=5000',
    expect.anything(),
  );
});

it.each([
  null,
  {},
  { endpoints: {} },
  { endpoints: 'private-response' },
  { endpoints: [null] },
  { endpoints: [{ tag: 'home/tailnet', peers: null }] },
])(
  'refuses malformed Tailscale state before either client consumes it: %j',
  async (payload) => {
    vi.stubGlobal('_', (value: string) => value);
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        status: 200,
        text: async () => JSON.stringify(payload),
      }),
    );
    const { getClashApiTailscale } = await import('../clashApi');
    expect(await getClashApiTailscale()).toEqual({
      success: false,
      error: 'Invalid Clash API response',
    });
  },
);

it('keeps an empty Tailscale endpoint list as a successful reply', async () => {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      status: 200,
      text: async () => '{"endpoints":[]}',
    }),
  );
  const { getClashApiTailscale } = await import('../clashApi');
  expect(await getClashApiTailscale()).toEqual({
    success: true,
    data: { endpoints: [] },
  });
});

const validTailscaleEndpoint = {
  tag: 'home/tailnet',
  state: 'Running',
  connected: true,
  addresses: ['100.64.0.1'],
  routes: [],
  health: [],
  peers: [],
};

it.each([
  { addresses: null },
  { addresses: [123] },
  { health: 'bad' },
  { routes: {} },
  { routes: [null] },
  { routes: [{ prefix: null }] },
  { peers: {} },
  { peers: [null] },
  { peers: [{ name: {}, addresses: [] }] },
  { peers: [{ name: 'phone', addresses: null }] },
  { peers: [{ name: 'phone', addresses: [], subnets: {} }] },
])(
  'refuses malformed arrays used by the Tailscale dialog and exit-node picker: %j',
  async (fields) => {
    vi.stubGlobal('_', (value: string) => value);
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        status: 200,
        text: async () =>
          JSON.stringify({
            endpoints: [{ ...validTailscaleEndpoint, ...fields }],
          }),
      }),
    );
    const { getClashApiTailscale } = await import('../clashApi');
    expect(await getClashApiTailscale()).toEqual({
      success: false,
      error: 'Invalid Clash API response',
    });
  },
);

it('keeps a valid Tailscale endpoint without rewriting its fields', async () => {
  const data = {
    endpoints: [
      {
        ...validTailscaleEndpoint,
        authURL: 'https://login.example/a/1',
        routes: [{ prefix: '192.0.2.0/24', approved: false }],
        peers: [
          {
            name: 'phone',
            addresses: ['100.64.0.2'],
            online: true,
            exitNode: false,
            exitNodeOption: true,
          },
        ],
      },
    ],
  };
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      status: 200,
      text: async () => JSON.stringify(data),
    }),
  );
  const { getClashApiTailscale } = await import('../clashApi');
  expect(await getClashApiTailscale()).toEqual({ success: true, data });
});

it('checks malformed Tailscale state received through the CLI transport too', async () => {
  vi.stubGlobal('_', (value: string) => value);
  vi.stubGlobal(
    'fetch',
    vi.fn().mockRejectedValue(new TypeError('unreachable')),
  );
  mocks.clashApi.mockResolvedValue({
    success: true,
    data: { status: 200, body: '{"endpoints":{}}' },
  });
  const { getClashApiTailscale } = await import('../clashApi');
  expect(await getClashApiTailscale()).toEqual({
    success: false,
    error: 'Invalid Clash API response',
  });
});
