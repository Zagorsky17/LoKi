import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Loki } from '../../../types';

const mocks = vi.hoisted(() => ({
  renderSections: vi.fn(),
  getClashApiProxyExit: vi.fn(),
  copyToClipboard: vi.fn(),
}));

vi.mock('../../../services/socket.service', () => ({
  socket: { subscribe: vi.fn(), disconnect: vi.fn(), resetAll: vi.fn() },
}));
vi.mock('../../../../helpers/onMount', () => ({ onMount: async () => ({}) }));
vi.mock('../../../../helpers/copyToClipboard', () => ({
  copyToClipboard: mocks.copyToClipboard,
}));
vi.mock('../partials', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../partials')>()),
  renderSections: mocks.renderSections,
  renderSectionsPlaceholder: () => ({}),
  renderToolbar: () => [],
  renderWidget: () => ({}),
}));
vi.mock('../coreUsage', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../coreUsage')>()),
  readCoreUsage: async () => ({
    success: false,
    message: '',
    unavailable: true,
  }),
}));

const section: Loki.OutboundGroup = {
  code: 'main-out',
  sectionName: 'main',
  displayName: 'Main',
  withTagSelect: true,
  outbounds: [
    {
      code: 'main-1-out',
      displayName: '🇳🇱 Amsterdam',
      latency: 40,
      type: 'VLESS',
      selected: true,
    },
    {
      code: 'main-2-out',
      displayName: '🇩🇪 Frankfurt',
      latency: 50,
      type: 'VLESS',
      selected: false,
    },
  ],
};

vi.mock('../../../methods', () => ({
  CustomLokiMethods: {
    getDashboardSections: async () => ({
      success: true,
      data: [section],
      hasRemoteLists: false,
    }),
    getClashApiConnectionsSummary: async () => ({ success: false }),
    getClashApiProxyExit: mocks.getClashApiProxyExit,
  },
}));

type SectionProps = {
  exitPanel?: {
    loading: boolean;
    report?: Loki.GetClashApiProxyExit;
    error?: string;
    nodeName?: string;
  };
  onToggleExit: () => void;
  onRefreshExit: () => void;
  onCopyExitAddress: (address: string) => void;
};

const listeners: Record<string, ((event: unknown) => void)[]> = {};

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

const report: Loki.GetClashApiProxyExit = {
  outbound: 'main-1-out',
  ipv4: { address: '203.0.113.7', country: 'NL' },
  ipv6: { error: 'connection refused' },
};

beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  mocks.renderSections.mockReset();
  mocks.renderSections.mockReturnValue({});
  mocks.getClashApiProxyExit.mockReset();
  mocks.copyToClipboard.mockReset();
  for (const type of Object.keys(listeners)) {
    delete listeners[type];
  }
  vi.stubGlobal('window', {
    location: { hostname: '192.168.1.1', protocol: 'http:' },
    scrollY: 0,
    scrollTo() {},
    addEventListener() {},
  });
  vi.stubGlobal('requestAnimationFrame', () => 0);
  vi.stubGlobal(
    'MutationObserver',
    class {
      observe() {}
    },
  );
  const container = { replaceChildren() {} };
  vi.stubGlobal('document', {
    visibilityState: 'visible',
    body: { classList: { contains: () => false } },
    getElementById: (id: string) =>
      id === 'dashboard-sections-grid' ? container : null,
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener: (type: string, listener: (event: unknown) => void) => {
      (listeners[type] ||= []).push(listener);
    },
    removeEventListener: (type: string, listener: (event: unknown) => void) => {
      listeners[type] = (listeners[type] || []).filter(
        (candidate) => candidate !== listener,
      );
    },
  });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

async function openDashboard() {
  const { store } = await import('../../../services/store.service');
  store.set({ tabService: { current: 'dashboard', all: [] } });
  const { initController } = await import('../initController');
  await initController();
  await vi.advanceTimersByTimeAsync(0);
}

function lastProps(): SectionProps {
  const calls = mocks.renderSections.mock.calls;
  return calls[calls.length - 1][0];
}

function press(target: { closest: (selector: string) => unknown }) {
  for (const listener of listeners.pointerdown || []) {
    listener({ target });
  }
}

describe('the exit panel of a section', () => {
  it('asks for the exit of the section selector and names the node the answer came through', async () => {
    const answer = deferred<unknown>();
    mocks.getClashApiProxyExit.mockReturnValue(answer.promise);
    await openDashboard();

    lastProps().onToggleExit();
    expect(mocks.getClashApiProxyExit).toHaveBeenCalledWith('main-out');
    expect(lastProps().exitPanel).toEqual({
      sectionName: 'main',
      loading: true,
      report: undefined,
      nodeName: '🇳🇱 Amsterdam',
    });

    answer.resolve({
      success: true,
      data: { ...report, outbound: 'main-2-out' },
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(lastProps().exitPanel).toMatchObject({
      loading: false,
      report: { outbound: 'main-2-out' },
      nodeName: '🇩🇪 Frankfurt',
    });

    lastProps().onCopyExitAddress('203.0.113.7');
    expect(mocks.copyToClipboard).toHaveBeenCalledWith('203.0.113.7');
  });

  it('keeps the last answer on screen while checking again', async () => {
    mocks.getClashApiProxyExit.mockResolvedValueOnce({
      success: true,
      data: report,
    });
    await openDashboard();
    lastProps().onToggleExit();
    await vi.advanceTimersByTimeAsync(0);

    const again = deferred<unknown>();
    mocks.getClashApiProxyExit.mockReturnValueOnce(again.promise);
    lastProps().onRefreshExit();
    expect(lastProps().exitPanel).toMatchObject({ loading: true, report });

    again.resolve({ success: false, error: 'Timeout', status: 504 });
    await vi.advanceTimersByTimeAsync(0);
    expect(lastProps().exitPanel).toMatchObject({
      loading: false,
      error: 'Timeout',
    });
    expect(lastProps().exitPanel?.report).toBeUndefined();
  });

  it('closes on a press outside it, on Escape and on its own button, and stays open for a press inside', async () => {
    mocks.getClashApiProxyExit.mockResolvedValue({
      success: true,
      data: report,
    });
    await openDashboard();

    lastProps().onToggleExit();
    await vi.advanceTimersByTimeAsync(0);
    press({ closest: () => ({}) });
    expect(lastProps().exitPanel).toBeDefined();
    press({ closest: () => null });
    expect(lastProps().exitPanel).toBeUndefined();

    lastProps().onToggleExit();
    await vi.advanceTimersByTimeAsync(0);
    for (const listener of listeners.keydown || []) {
      listener({ key: 'Escape' });
    }
    expect(lastProps().exitPanel).toBeUndefined();

    lastProps().onToggleExit();
    await vi.advanceTimersByTimeAsync(0);
    lastProps().onToggleExit();
    expect(lastProps().exitPanel).toBeUndefined();
  });

  it('drops an answer that arrives after the panel was closed', async () => {
    const answer = deferred<unknown>();
    mocks.getClashApiProxyExit.mockReturnValue(answer.promise);
    await openDashboard();

    lastProps().onToggleExit();
    press({ closest: () => null });
    answer.resolve({ success: true, data: report });
    await vi.advanceTimersByTimeAsync(0);

    expect(lastProps().exitPanel).toBeUndefined();
  });
});
