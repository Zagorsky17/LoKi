import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

const mocks = vi.hoisted(() => ({
  getClashApiTailscale: vi.fn(),
  pingClashApiTailscalePeer: vi.fn(),
  showModal: vi.fn(),
}));
vi.mock('../../../methods', () => ({
  CustomForkopMethods: {
    getClashApiTailscale: mocks.getClashApiTailscale,
    pingClashApiTailscalePeer: mocks.pingClashApiTailscalePeer,
  },
}));
vi.mock('../tailscaleDetails', () => ({
  iconSvg: () => ({ tag: 'svg', attrs: {}, children: [] }),
  injectDetailsStyles: () => {},
  renderCloseRow: () => ({ tag: 'div', attrs: {}, children: [] }),
  copyWithToast: () => {},
}));
vi.mock('../../../../icons', () => ({
  renderLoaderCircleIcon24: () => ({ tag: 'svg', attrs: {}, children: [] }),
  renderRotateCcwIcon24: () => ({ tag: 'svg', attrs: {}, children: [] }),
}));

interface Tree {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown;
  isConnected: boolean;
}

let module: typeof import('../tailscale');
const options: Record<string, string> = {};
let overlayShown = true;
beforeAll(async () => {
  vi.stubGlobal('_', (text: string) => text);
  vi.stubGlobal('E', (tag: string, attrs: unknown, children: unknown) => ({
    tag,
    attrs: attrs || {},
    children,
    isConnected: true,
  }));
  vi.stubGlobal('dom', {
    content: (node: Tree, children: unknown) => {
      node.children = children;
    },
  });
  vi.stubGlobal('ui', { showModal: mocks.showModal });
  vi.stubGlobal('uci', {
    get: (_config: string, _section: string, name: string) => options[name],
  });
  vi.stubGlobal('window', globalThis);
  vi.stubGlobal('document', {
    documentElement: { lang: 'en' },
    getElementById: () => ({}),
    body: { classList: { contains: () => overlayShown } },
  });
  module = await import('../tailscale');
});
afterAll(() => vi.unstubAllGlobals());

// String.prototype.format as LuCI adds it.
Object.defineProperty(String.prototype, 'format', {
  configurable: true,
  value(this: string, ...args: unknown[]) {
    let index = 0;
    return this.replace(/%[sd]/g, () => String(args[index++]));
  },
});

function texts(node: unknown): string[] {
  if (node == null) {
    return [];
  }
  if (typeof node === 'string') {
    return [node];
  }
  if (Array.isArray(node)) {
    return node.flatMap(texts);
  }
  return texts((node as Tree).children);
}

function stateClasses(node: unknown): string[] {
  if (Array.isArray(node)) {
    return node.flatMap(stateClasses);
  }
  if (!node || typeof node !== 'object') {
    return [];
  }
  const tree = node as Tree;
  const own = /fkp-ts--(\w+)/.exec(`${tree.attrs.class || ''}`);
  return [
    ...(own ? [`${own[1]}:${texts(tree.children).join('')}`] : []),
    ...stateClasses(tree.children),
  ];
}

function findAll(node: unknown, className: string): Tree[] {
  if (Array.isArray(node)) {
    return node.flatMap((child) => findAll(child, className));
  }
  if (!node || typeof node !== 'object') {
    return [];
  }
  const tree = node as Tree;
  const own = `${tree.attrs.class || ''}`.split(' ').includes(className)
    ? [tree]
    : [];
  return [...own, ...findAll(tree.children, className)];
}

const endpoint = (fields: object) => ({
  tag: 'Server #1',
  state: 'Running',
  connected: true,
  addresses: ['100.64.0.1'],
  advertisesExitNode: true,
  exitNodeApproved: true,
  routes: [],
  health: [],
  peers: [],
  ...fields,
});

const tunnel = (fields: object) =>
  endpoint({ tag: 'home/tailnet', advertisesExitNode: false, ...fields });

const peer = (fields: object) => ({
  name: 'phone',
  addresses: ['100.64.0.2'],
  online: true,
  exitNodeOption: false,
  exitNode: false,
  ...fields,
});

const noPings = () => ({ results: new Map(), ping: () => {} });

function render(load: object, pings = noPings()) {
  return module.renderTailscaleContent(load, 'not running', pings);
}

describe('the Tailscale dialog', () => {
  it('tells a live session from one the coordination server lost', () => {
    expect(stateClasses(render({ endpoint: endpoint({}) }))).toContain(
      'ok:Online',
    );
    expect(
      stateClasses(render({ endpoint: endpoint({ connected: false }) })),
    ).toContain('error:No connection to the coordination server');
  });

  it('offers the sign-in link while the device waits for it', () => {
    const content = render({
      endpoint: endpoint({
        state: 'NeedsLogin',
        authURL: 'https://login.tailscale.com/a/1',
      }),
    });
    expect(stateClasses(content)).toContain('warn:Waiting for sign-in');
    expect(texts(content)).toContain('Sign in');
  });

  it.each([
    'javascript:alert(1)',
    'data:text/html,<script>alert(1)</script>',
    'file:///etc/config/forkop',
    '//login.example/sign-in',
    'https://invalid host/sign-in',
    '',
  ])(
    'does not turn an unsafe authentication URL into a link: %s',
    (authURL) => {
      const content = render({
        endpoint: endpoint({ state: 'NeedsLogin', authURL }),
      });
      expect(texts(content)).not.toContain('Sign in');
      expect(stateClasses(content)).toContain('warn:Waiting for sign-in');
    },
  );

  it.each(['https://login.example/a/1', 'http://headscale.lan:8080/a/1'])(
    'keeps a valid coordination-server authentication link: %s',
    (authURL) => {
      const content = render({
        endpoint: endpoint({ state: 'NeedsLogin', authURL }),
      });
      expect(texts(content)).toContain('Sign in');
    },
  );

  it('names the device as the tailnet does, its addresses on one line', () => {
    const content = render({
      endpoint: endpoint({
        name: 'forkop-3',
        addresses: ['100.64.0.1', 'fd7a::1'],
        tailnet: 'hs.example.net',
      }),
    });
    expect(findAll(content, 'fkp-ts__who').map(texts)).toEqual([['forkop-3']]);
    // Each a link that copies it, the name of the tailnet too.
    expect(findAll(content, 'fkp-ts__address').map(texts)).toEqual([
      ['100.64.0.1'],
      ['fd7a::1'],
      ['hs.example.net'],
    ]);
  });

  it('marks a device online by its name, and says when one was last online', () => {
    const content = (fields: object) =>
      render({ endpoint: endpoint({ peers: [peer(fields)] }) });
    const online = content({ online: true });
    expect(
      findAll(online, 'fkp-ts__dot').map((dot) => dot.attrs.title),
    ).toEqual(['Online now']);
    expect(texts(findAll(online, 'fkp-ts__device-meta'))).toEqual(['N/A']);
    expect(findAll(content({ online: false }), 'fkp-ts__dot')).toEqual([]);
    expect(stateClasses(content({ online: false }))).toContain('muted:Offline');

    const lastSeen = Math.round(Date.now() / 1000 - 7200);
    const [age] = findAll(
      findAll(content({ online: false, lastSeen }), 'fkp-ts__device-meta'),
      'fkp-ts--muted',
    );
    expect(texts(age)).toEqual(['2 hr. ago']);
    expect(age.attrs.title).toBe(
      `Last online ${new Date(lastSeen * 1000).toLocaleString('en', {
        dateStyle: 'medium',
        timeStyle: 'short',
      })}`,
    );
  });

  it('names no owner of a device, however many the tailnet has', () => {
    const content = render({
      endpoint: endpoint({
        peers: [
          { ...peer({ name: 'phone' }), user: 'rem' },
          { ...peer({ name: 'tv' }), user: 'ultra' },
        ],
      }),
    });
    expect(texts(content)).not.toEqual(expect.arrayContaining(['rem']));
    expect(texts(content)).not.toEqual(expect.arrayContaining(['ultra']));
  });

  it('marks the exit node and each route by their approval', () => {
    const states = stateClasses(
      render({
        endpoint: endpoint({
          exitNodeApproved: false,
          routes: [
            { prefix: '192.168.1.0/24', approved: true },
            { prefix: '10.0.0.0/8', approved: false },
          ],
        }),
      }),
    );
    expect(states).toEqual([
      'ok:Online',
      'warn:Waiting for approval in the console',
      'ok:Approved',
      'warn:Waiting for approval in the console',
      'muted:Does not expire',
    ]);
  });

  it('names the exit node a tunnel uses, or the one it waits for', () => {
    const exitNode = (fields: object) => {
      const params = render({ endpoint: tunnel(fields) })[0] as unknown as Tree;
      const row = (params.children as Tree[]).find(
        (item) => texts(item)[0] === 'Exit node',
      );
      // What the row says, then how many devices it names and how many of them are online.
      return [
        texts(row).slice(1).join(' '),
        findAll(row, 'fkp-ts__who').length,
        findAll(row, 'fkp-ts__dot').length,
      ];
    };
    expect(
      exitNode({
        exitNode: 'router',
        peers: [peer({ name: 'router', exitNode: true })],
      }),
    ).toEqual(['router', 1, 1]);
    expect(
      exitNode({
        peers: [peer({ name: 'router', exitNode: true, online: false })],
      }),
    ).toEqual(['router Offline', 1, 0]);
    expect(exitNode({ exitNode: 'router', peers: [peer({})] })).toEqual([
      'router Not in use',
      1,
      0,
    ]);
    expect(exitNode({})).toEqual(['Not set', 0, 0]);
    expect(stateClasses(render({ endpoint: tunnel({}) }))).toContain(
      'warn:Not set',
    );
  });

  it('marks the devices that can be an exit node and the subnets each shares', () => {
    const content = render({
      endpoint: tunnel({
        peers: [
          peer({ name: 'router', exitNodeOption: true, exitNode: true }),
          peer({ name: 'nas', subnets: ['192.168.10.0/24', 'fd00:10::/64'] }),
        ],
      }),
    });
    const [router, nas] = findAll(content, 'fkp-ts__device');
    expect(findAll(router, 'fkp-ts__chip--active').map(texts)).toEqual([
      ['Exit node'],
    ]);
    expect(texts(nas)).toContain('192.168.10.0/24, fd00:10::/64');
    expect(findAll(nas, 'fkp-ts__chip')).toEqual([]);
  });

  it('offers a ping to an online device only', () => {
    const content = render({
      endpoint: tunnel({
        peers: [peer({ name: 'phone' }), peer({ name: 'tv', online: false })],
      }),
    });
    const [phone, tv] = findAll(content, 'fkp-ts__device');
    expect(findAll(phone, 'fkp-ts__ping').map(texts)).toEqual([['N/A']]);
    expect(findAll(tv, 'fkp-ts__ping')).toEqual([]);
  });

  it('explains an endpoint the core does not report', () => {
    expect(texts(render({}))).toEqual(['not running']);
    expect(texts(render({ error: 'timeout' }))).toEqual([
      'Failed to get the Tailscale state: timeout',
    ]);
  });
});

describe('the open Tailscale dialog', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    overlayShown = true;
    mocks.showModal.mockReset();
    mocks.getClashApiTailscale.mockReset().mockResolvedValue({
      success: true,
      data: { endpoints: [tunnel({ peers: [peer({ name: 'phone' })] })] },
    });
    mocks.pingClashApiTailscalePeer.mockReset();
  });
  afterEach(() => vi.useRealTimers());

  async function open() {
    module.showTailscaleDetailsModal(
      'Tailscale details: tailnet',
      'home/tailnet',
      'not running',
    );
    await vi.advanceTimersByTimeAsync(0);
    const [title, children] = mocks.showModal.mock.calls[0];
    return { title, content: (children as Tree[])[0] };
  }

  it('pings a device and shows how long the answer took', async () => {
    const answers: Array<(value: object) => void> = [];
    mocks.pingClashApiTailscalePeer.mockImplementation(
      () => new Promise((resolve) => answers.push(resolve)),
    );
    const { content } = await open();
    const button = () => findAll(content, 'fkp-ts__ping')[0];

    (button().attrs.click as () => void)();
    expect(mocks.pingClashApiTailscalePeer).toHaveBeenCalledWith(
      'home/tailnet',
      '100.64.0.2',
    );
    expect([button().attrs['aria-busy'], texts(button())]).toEqual([
      'true',
      ['N/A'],
    ]);
    expect(button().attrs.class).toContain('latency--empty');

    answers[0]({ success: true, data: { latency: 12.4 } });
    await vi.advanceTimersByTimeAsync(0);
    expect(texts(findAll(content, 'fkp-ts__device-meta'))).toEqual(['12ms']);
    expect(button().attrs.class).toContain('latency--green');

    // The ping outlives the refresh that redraws the list, and the next one keeps it while it runs.
    await vi.advanceTimersByTimeAsync(5000);
    (button().attrs.click as () => void)();
    expect([button().attrs['aria-busy'], texts(button())]).toEqual([
      'true',
      ['12ms'],
    ]);
  });

  it('shows N/A for a device that did not answer, and why on hover', async () => {
    const { content } = await open();
    const button = () => findAll(content, 'fkp-ts__ping')[0];

    mocks.pingClashApiTailscalePeer.mockResolvedValue({
      success: false,
      error: 'Timeout',
      status: 504,
    });
    (button().attrs.click as () => void)();
    await vi.advanceTimersByTimeAsync(0);
    expect([button().attrs.title, texts(button())]).toEqual([
      'no answer',
      ['N/A'],
    ]);

    mocks.pingClashApiTailscalePeer.mockResolvedValue({
      success: false,
      error: 'no matching peer',
      status: 503,
    });
    (button().attrs.click as () => void)();
    await vi.advanceTimersByTimeAsync(0);
    expect(button().attrs.title).toBe('no matching peer');

    mocks.pingClashApiTailscalePeer.mockResolvedValue({
      success: true,
      data: { latency: 0.4 },
    });
    (button().attrs.click as () => void)();
    await vi.advanceTimersByTimeAsync(0);
    expect([button().attrs.title, texts(button())]).toEqual([
      'Ping the device',
      ['<1ms'],
    ]);
  });

  it('stops asking the core once the dialog is closed', async () => {
    await open();
    await vi.advanceTimersByTimeAsync(5000);
    expect(mocks.getClashApiTailscale).toHaveBeenCalledTimes(2);

    overlayShown = false;
    await vi.advanceTimersByTimeAsync(25000);
    expect(mocks.getClashApiTailscale).toHaveBeenCalledTimes(2);
  });
});
