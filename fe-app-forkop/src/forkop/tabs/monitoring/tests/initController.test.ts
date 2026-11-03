import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getClashApiConnections: vi.fn(),
  getConfigSections: vi.fn(),
  closeClashApiConnection: vi.fn(),
  closeAllClashApiConnections: vi.fn(),
  deviceNames: {} as Record<string, string>,
}));

vi.mock('../../../services/socket.service', () => ({
  socket: { subscribe: vi.fn(), disconnect: vi.fn(), resetAll: vi.fn() },
}));
vi.mock('../../../../helpers/onMount', () => ({ onMount: async () => ({}) }));
vi.mock('../../../../helpers/showToast', () => ({ showToast: vi.fn() }));
vi.mock('../../../methods', () => ({
  CustomForkopMethods: {
    getClashApiConnections: mocks.getClashApiConnections,
    getConfigSections: mocks.getConfigSections,
    closeClashApiConnection: mocks.closeClashApiConnection,
    closeAllClashApiConnections: mocks.closeAllClashApiConnections,
  },
}));
vi.mock('../../../methods/custom/getClashApiSecret', () => ({
  getClashApiSecret: async () => 'secret',
}));
vi.mock('../../../methods/custom/clashApi', () => ({
  resetClashApiTransport: vi.fn(),
}));
vi.mock('../../../cbi/localDevices', () => ({
  loadLocalDevices: async () => ({
    choices: {},
    order: [],
    names: mocks.deviceNames,
  }),
}));
vi.mock('../../../../icons', () => ({
  renderChevronUpIcon24: () => new FakeElement('svg'),
  renderSearchIcon24: () => new FakeElement('svg'),
  renderXIcon24: () => new FakeElement('svg'),
}));

type Child = FakeElement | string;

class FakeElement {
  tag: string;
  attrs: Record<string, unknown>;
  children: Child[] = [];
  parent: FakeElement | null = null;
  [property: string]: unknown;

  constructor(
    tag: string,
    attrs: Record<string, unknown> = {},
    children?: unknown,
  ) {
    this.tag = tag;
    this.attrs = attrs;
    Object.assign(this, attrs);
    this.classList = { toggle() {} };
    this.replaceChildren(
      ...((Array.isArray(children) ? children : [children]).filter(
        (child) => child != null,
      ) as Child[]),
    );
  }

  replaceChildren(...children: Child[]) {
    this.children = children;
    children.forEach((child) => {
      if (typeof child !== 'string') {
        child.parent = this;
      }
    });
  }

  closest(selector: string): FakeElement | null {
    return `${this.attrs.class}`.split(' ').includes(selector.slice(1))
      ? this
      : (this.parent?.closest(selector) ?? null);
  }

  get childNodes() {
    return this.children;
  }

  get textContent(): string {
    return this.children
      .map((child) => (typeof child === 'string' ? child : child.textContent))
      .join('');
  }

  set textContent(value: string) {
    this.children = [String(value)];
  }

  contains(node: unknown): boolean {
    return (
      node === this ||
      this.children.some(
        (child) => typeof child !== 'string' && child.contains(node),
      )
    );
  }

  descendants(): FakeElement[] {
    return [
      this,
      ...this.children.flatMap((child) =>
        typeof child === 'string' ? [] : child.descendants(),
      ),
    ];
  }
}

let page: FakeElement;
let selection: {
  isCollapsed: boolean;
  anchorNode: unknown;
  focusNode: unknown;
};
const documentListeners = new Map<string, Set<() => void>>();

function byId(id: string) {
  return page.descendants().find((element) => element.id === id) as FakeElement;
}

function connection(
  id: string,
  {
    sourceIP = '192.168.1.101',
    type = 'tproxy/tproxy-in',
    chains = ['direct-out'],
    rule = '',
    ageSeconds = 0,
    download = 0,
    upload = 0,
  } = {},
) {
  return {
    id,
    rule,
    metadata: {
      host: `${id}.example.com`,
      destinationPort: '443',
      network: 'tcp',
      sourceIP,
      type,
    },
    chains,
    start: new Date(Date.now() - ageSeconds * 1000).toISOString(),
    download,
    upload,
  };
}

function answerWith(...connections: ReturnType<typeof connection>[]) {
  mocks.getClashApiConnections.mockResolvedValue({
    success: true,
    data: { connections },
  });
}

function answer(...ids: string[]) {
  answerWith(...ids.map((id) => connection(id)));
}

function choose(id: string, value: string) {
  const filter = byId(id);
  filter.value = value;
  (filter.onchange as () => void)();
}

function optionTexts(id: string) {
  return byId(id).children.map((option) =>
    typeof option === 'string' ? option : option.textContent,
  );
}

function hosts() {
  return rows().map((row) => row.descendants()[1].textContent);
}

function rows() {
  return byId('monitoring-connections')
    .descendants()
    .filter(
      (element) =>
        element.attrs.role === 'row' &&
        !`${element.attrs.class}`.includes('--head'),
    );
}

function sources() {
  return rows().map((row) => {
    const value = row
      .descendants()
      .find((element) => `${element.attrs.class}`.includes('__cell--source'))
      ?.children[0] as FakeElement;

    return [
      value.textContent,
      `${value.attrs.class}`.includes('__tag--builtin'),
    ];
  });
}

function activeCount() {
  return byId('monitoring-tab-active').textContent.replace(/\D/g, '');
}

function showTab(id: string) {
  (byId(id).onclick as (event: unknown) => void)({ preventDefault() {} });
}

function sortBy(column: string) {
  const list = byId('monitoring-connections');
  const button = list
    .descendants()
    .find(
      (element) =>
        `${element.attrs.class}`.includes('__sort') &&
        element.attrs.value === column,
    );
  (list.onclick as (event: unknown) => void)({ target: button });
}

function sortedColumn() {
  const heading = byId('monitoring-connections')
    .descendants()
    .find((element) => element.attrs['aria-sort']);
  const button = heading?.descendants().find((element) => element !== heading);

  return heading ? `${button?.attrs.value} ${heading.attrs['aria-sort']}` : '';
}

function select(node: unknown) {
  selection = { isCollapsed: node == null, anchorNode: node, focusNode: node };
  documentListeners.get('selectionchange')?.forEach((listener) => listener());
}

beforeEach(async () => {
  vi.resetModules();
  vi.useFakeTimers();
  mocks.getClashApiConnections.mockReset();
  mocks.getConfigSections.mockReset().mockResolvedValue([]);
  mocks.closeClashApiConnection
    .mockReset()
    .mockResolvedValue({ success: true });
  mocks.closeAllClashApiConnections
    .mockReset()
    .mockResolvedValue({ success: true });
  mocks.deviceNames = {};
  documentListeners.clear();
  selection = { isCollapsed: true, anchorNode: null, focusNode: null };

  vi.stubGlobal(
    'E',
    (tag: string, attrs?: Record<string, unknown>, children?: unknown) =>
      new FakeElement(tag, attrs, children),
  );
  vi.stubGlobal('window', { getSelection: () => selection });
  vi.stubGlobal(
    'MutationObserver',
    class {
      observe() {}
    },
  );
  vi.stubGlobal('document', {
    visibilityState: 'visible',
    body: {},
    getElementById: (id: string) => byId(id) ?? null,
    querySelector: (query: string) =>
      page
        .descendants()
        .find((element) => `${element.attrs.class}` === query.slice(1)) ?? null,
    querySelectorAll: () => [],
    addEventListener: (type: string, listener: () => void) => {
      if (!documentListeners.has(type)) {
        documentListeners.set(type, new Set());
      }
      documentListeners.get(type)?.add(listener);
    },
    removeEventListener: (type: string, listener: () => void) =>
      documentListeners.get(type)?.delete(listener),
  });

  const { render } = await import('../render');
  page = render() as unknown as FakeElement;
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

async function openMonitoring() {
  const { store } = await import('../../../services/store.service');
  store.set({ tabService: { current: 'monitoring', all: [] } });
  const { initController } = await import('../initController');
  await initController();
  await vi.advanceTimersByTimeAsync(0);
}

async function closeOne(id: string) {
  const list = byId('monitoring-connections');
  const button = list
    .descendants()
    .find(
      (node) =>
        node.value === id && `${node.attrs.class}`.includes('__row-action'),
    );
  expect(button).toBeTruthy();
  (list.onclick as (event: unknown) => void)({ target: button });
  await vi.advanceTimersByTimeAsync(0);
}

describe('the Monitoring close controls', () => {
  it('moves an acknowledged close-one from active to closed and updates both counters', async () => {
    answer('a', 'b');
    await openMonitoring();
    await closeOne('a');
    expect(mocks.closeClashApiConnection).toHaveBeenCalledWith('a');
    expect([hosts(), activeCount()]).toEqual([['b.example.com'], '1']);
    expect(byId('monitoring-tab-closed').textContent.replace(/\D/g, '')).toBe(
      '1',
    );
    showTab('monitoring-tab-closed');
    expect(hosts()).toEqual(['a.example.com']);
  });

  it('moves an acknowledged close-all to the closed list', async () => {
    answer('a', 'b');
    await openMonitoring();
    (byId('monitoring-close-all').onclick as () => void)();
    await vi.advanceTimersByTimeAsync(0);
    expect(mocks.closeAllClashApiConnections).toHaveBeenCalledOnce();
    expect(activeCount()).toBe('0');
    showTab('monitoring-tab-closed');
    expect(hosts().sort()).toEqual(['a.example.com', 'b.example.com']);
  });

  it('preserves active rows when write authorization refuses close-one and close-all', async () => {
    mocks.closeClashApiConnection.mockResolvedValue({
      success: false,
      error: 'permission denied',
    });
    mocks.closeAllClashApiConnections.mockResolvedValue({
      success: false,
      error: 'permission denied',
    });
    answer('a', 'b');
    await openMonitoring();
    await closeOne('a');
    (byId('monitoring-close-all').onclick as () => void)();
    await vi.advanceTimersByTimeAsync(0);
    expect([rows().length, activeCount()]).toEqual([2, '2']);
    expect(byId('monitoring-tab-closed').textContent.replace(/\D/g, '')).toBe(
      '0',
    );
  });

  it('closes only matching rows when device filtering is active', async () => {
    answerWith(connection('a'), connection('b', { sourceIP: '192.168.1.102' }));
    await openMonitoring();
    choose('monitoring-device-filter', '192.168.1.101');
    (byId('monitoring-close-all').onclick as () => void)();
    await vi.advanceTimersByTimeAsync(0);
    expect(mocks.closeClashApiConnection).toHaveBeenCalledWith('a');
    expect(mocks.closeAllClashApiConnections).not.toHaveBeenCalled();
    choose('monitoring-device-filter', '');
    expect(hosts()).toEqual(['b.example.com']);
  });
});

describe('the Monitoring pause', () => {
  it('holds new connections back while Auto refresh is off', async () => {
    answer('a');
    await openMonitoring();
    expect(rows()).toHaveLength(1);

    const autoRefresh = byId('monitoring-auto-refresh');
    autoRefresh.checked = false;
    (autoRefresh.onchange as () => void)();
    answer('a', 'b');
    await vi.advanceTimersByTimeAsync(5000);
    expect([rows().length, activeCount()]).toEqual([1, '1']);

    autoRefresh.checked = true;
    (autoRefresh.onchange as () => void)();
    await vi.advanceTimersByTimeAsync(0);
    expect([rows().length, activeCount()]).toEqual([2, '2']);
  });

  it('holds the whole tab while text in the list is selected and says so', async () => {
    answer('a');
    await openMonitoring();
    const note = byId('monitoring-pause-note');
    expect(note.hidden).toBe(true);

    select(rows()[0].descendants()[1]);
    answer('a', 'b');
    await vi.advanceTimersByTimeAsync(5000);
    expect([rows().length, activeCount()]).toEqual([1, '1']);
    expect(note.hidden).toBe(false);
    expect(byId('monitoring-auto-refresh').checked).toBe(true);

    select(null);
    await vi.advanceTimersByTimeAsync(0);
    expect([rows().length, activeCount()]).toEqual([2, '2']);
    expect(note.hidden).toBe(true);
  });

  it('keeps the list live while text outside it is selected', async () => {
    answer('a');
    await openMonitoring();

    select(byId('monitoring-tab-active'));
    answer('a', 'b');
    await vi.advanceTimersByTimeAsync(5000);
    expect([rows().length, activeCount()]).toEqual([2, '2']);
    expect(byId('monitoring-pause-note').hidden).toBe(true);
  });

  it('leaves the note to the switch when Auto refresh is off anyway', async () => {
    answer('a');
    await openMonitoring();
    const autoRefresh = byId('monitoring-auto-refresh');
    autoRefresh.checked = false;
    (autoRefresh.onchange as () => void)();

    select(rows()[0].descendants()[1]);
    expect(byId('monitoring-pause-note').hidden).toBe(true);

    select(null);
    answer('a', 'b');
    await vi.advanceTimersByTimeAsync(5000);
    expect(rows()).toHaveLength(1);
  });
});

describe('the Monitoring order', () => {
  it('lists the newest connection first, the shortest time', async () => {
    answerWith(
      connection('a', { ageSeconds: 60 }),
      connection('b', { ageSeconds: 10 }),
      connection('c', { ageSeconds: 30 }),
    );
    await openMonitoring();

    expect(hosts()).toEqual([
      'b.example.com',
      'c.example.com',
      'a.example.com',
    ]);
    expect(sortedColumn()).toBe('time ascending');
  });

  it('turns the time over to the longest first', async () => {
    answerWith(
      connection('a', { ageSeconds: 60 }),
      connection('b', { ageSeconds: 10 }),
    );
    await openMonitoring();

    sortBy('time');
    expect([hosts(), sortedColumn()]).toEqual([
      ['a.example.com', 'b.example.com'],
      'time descending',
    ]);
  });

  it('sorts by traffic the most first and turns it over on a second click', async () => {
    answerWith(
      connection('a', { download: 100, upload: 70 }),
      connection('b', { download: 3000, upload: 5 }),
      connection('c', { download: 20, upload: 1 }),
    );
    await openMonitoring();

    sortBy('download');
    expect([hosts(), sortedColumn()]).toEqual([
      ['b.example.com', 'a.example.com', 'c.example.com'],
      'download descending',
    ]);

    sortBy('download');
    expect([hosts(), sortedColumn()]).toEqual([
      ['c.example.com', 'a.example.com', 'b.example.com'],
      'download ascending',
    ]);

    sortBy('upload');
    expect([hosts(), sortedColumn()]).toEqual([
      ['a.example.com', 'b.example.com', 'c.example.com'],
      'upload descending',
    ]);
  });

  it('lists the last closed first until a column is chosen', async () => {
    const shortLived = connection('a', { ageSeconds: 10 });
    const longLived = connection('b', { ageSeconds: 100 });
    answerWith(shortLived, longLived);
    await openMonitoring();
    answerWith(longLived);
    await vi.advanceTimersByTimeAsync(2000);
    answerWith();
    await vi.advanceTimersByTimeAsync(2000);

    showTab('monitoring-tab-closed');
    expect([hosts(), sortedColumn()]).toEqual([
      ['b.example.com', 'a.example.com'],
      '',
    ]);

    sortBy('time');
    expect([hosts(), sortedColumn()]).toEqual([
      ['a.example.com', 'b.example.com'],
      'time ascending',
    ]);
  });
});

describe('the Monitoring sources', () => {
  it('tells the router itself from a device named System', async () => {
    mocks.deviceNames = { '192.168.1.101': 'System' };
    answerWith(
      connection('a', { ageSeconds: 2 }),
      connection('b', {
        sourceIP: '192.168.1.1',
        type: 'tproxy/system-in',
        ageSeconds: 1,
      }),
    );
    await openMonitoring();

    expect(sources()).toEqual([
      ['System', true],
      ['System 192.168.1.101', false],
    ]);
  });
});

describe('the Monitoring filters', () => {
  it('shows only the connections of the chosen device', async () => {
    answerWith(connection('a'), connection('b', { sourceIP: '192.168.1.102' }));
    await openMonitoring();
    expect(optionTexts('monitoring-device-filter')).toEqual([
      'All devices',
      '192.168.1.101',
      '192.168.1.102',
    ]);

    choose('monitoring-device-filter', '192.168.1.102');
    expect([hosts(), activeCount()]).toEqual([['b.example.com'], '1']);
    expect(byId('monitoring-close-all').textContent).toBe('Close matching');

    choose('monitoring-device-filter', '');
    expect([rows().length, activeCount()]).toEqual([2, '2']);
    expect(byId('monitoring-close-all').textContent).toBe('Close all');
  });

  it('shows only the connections of the chosen route', async () => {
    mocks.getConfigSections.mockResolvedValue([
      { '.name': 'section_b', '.type': 'section', label: 'proxy' },
      { '.name': 'section_a', '.type': 'section', label: 'google' },
      { '.name': 'section_c', '.type': 'section', label: 'off', enabled: '0' },
    ]);
    answerWith(
      connection('a'),
      connection('b', { chains: ['google/node', 'google'] }),
      connection('c', { chains: ['proxy/node', 'proxy'] }),
      connection('d', { chains: [], rule: 'final => route(other-out)' }),
    );
    await openMonitoring();
    expect(optionTexts('monitoring-route-filter')).toEqual([
      'All routes',
      'Direct',
      'proxy',
      'google',
      'other-out',
    ]);

    choose('monitoring-route-filter', 'google');
    expect([hosts(), activeCount()]).toEqual([['b.example.com'], '1']);
    expect(byId('monitoring-close-all').textContent).toBe('Close matching');

    choose('monitoring-route-filter', '');
    expect([rows().length, activeCount()]).toEqual([4, '4']);
    expect(byId('monitoring-close-all').textContent).toBe('Close all');
  });

  it('tells a route named all from all routes', async () => {
    mocks.getConfigSections.mockResolvedValue([
      { '.name': 'section_a', '.type': 'section', label: 'all' },
    ]);
    answerWith(connection('a'), connection('b', { chains: ['all'] }));
    await openMonitoring();

    choose('monitoring-route-filter', 'all');
    expect([hosts(), activeCount()]).toEqual([['b.example.com'], '1']);
  });

  it('tells a section named Direct from the direct route', async () => {
    mocks.getConfigSections.mockResolvedValue([
      { '.name': 'section_a', '.type': 'section', label: 'Direct' },
    ]);
    answerWith(connection('a'), connection('b', { chains: ['Direct'] }));
    await openMonitoring();
    expect(optionTexts('monitoring-route-filter')).toEqual([
      'All routes',
      'Direct',
      'Direct',
    ]);

    choose('monitoring-route-filter', 'Direct');
    expect([hosts(), activeCount()]).toEqual([['b.example.com'], '1']);

    choose('monitoring-route-filter', 'direct-out');
    expect([hosts(), activeCount()]).toEqual([['a.example.com'], '1']);
  });

  it('combines the device and the route', async () => {
    answerWith(
      connection('a'),
      connection('b', { chains: [], rule: 'final => route(other-out)' }),
      connection('c', {
        sourceIP: '192.168.1.102',
        chains: [],
        rule: 'final => route(other-out)',
      }),
    );
    await openMonitoring();

    choose('monitoring-route-filter', 'other-out');
    choose('monitoring-device-filter', '192.168.1.101');
    expect([hosts(), activeCount()]).toEqual([['b.example.com'], '1']);
  });
});
