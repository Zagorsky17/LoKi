import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  subscribe: vi.fn(),
  disconnect: vi.fn(),
  resetAll: vi.fn(),
  readCoreUsage: vi.fn(),
  getClashApiConnectionsSummary: vi.fn(),
}));

vi.mock('../../../services/socket.service', () => ({
  socket: {
    subscribe: mocks.subscribe,
    disconnect: mocks.disconnect,
    resetAll: mocks.resetAll,
  },
}));
vi.mock('../../../../helpers/onMount', () => ({ onMount: async () => ({}) }));
vi.mock('../../../methods', () => ({
  CustomForkopMethods: {
    getDashboardSections: async () => ({ success: false, data: [] }),
    getClashApiConnectionsSummary: mocks.getClashApiConnectionsSummary,
  },
}));
vi.mock('../../../methods/custom/getClashApiSecret', () => ({
  getClashApiSecret: async () => 'secret',
}));
vi.mock('../coreUsage', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../coreUsage')>()),
  readCoreUsage: mocks.readCoreUsage,
}));

let visibilityState = 'visible';
const visibilityListeners = new Set<() => void>();

beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  mocks.subscribe.mockReset();
  mocks.disconnect.mockReset();
  mocks.resetAll.mockReset();
  mocks.readCoreUsage.mockReset();
  mocks.getClashApiConnectionsSummary
    .mockReset()
    .mockResolvedValue({
      success: true,
      data: { downloadTotal: 10, uploadTotal: 5, connections: 2 },
    });
  vi.stubGlobal('L', { hasViewPermission: () => true });
  mocks.readCoreUsage.mockResolvedValue({
    success: false,
    message: '',
    unavailable: true,
  });
  visibilityState = 'visible';
  visibilityListeners.clear();
  vi.stubGlobal('window', {
    location: { hostname: '192.168.1.1', protocol: 'http:' },
    addEventListener() {},
  });
  vi.stubGlobal(
    'MutationObserver',
    class {
      observe() {}
    },
  );
  vi.stubGlobal('document', {
    get visibilityState() {
      return visibilityState;
    },
    body: {},
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener: (type: string, listener: () => void) => {
      if (type === 'visibilitychange') {
        visibilityListeners.add(listener);
      }
    },
    removeEventListener: (_type: string, listener: () => void) =>
      visibilityListeners.delete(listener),
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
  return {
    switchTo: (tab: string) =>
      store.set({ tabService: { current: tab, all: [] } }),
  };
}

function setVisibility(state: string) {
  visibilityState = state;
  for (const listener of visibilityListeners) {
    listener();
  }
}

function subscribedPaths() {
  return mocks.subscribe.mock.calls.map(([url]) => new URL(url).pathname);
}

describe('the dashboard sockets', () => {
  it('keeps reader summary polling live without opening bearer sockets', async () => {
    vi.stubGlobal('L', { hasViewPermission: () => false });
    await openDashboard();
    await vi.advanceTimersByTimeAsync(6000);
    expect(mocks.subscribe).not.toHaveBeenCalled();
    expect(
      mocks.getClashApiConnectionsSummary.mock.calls.length,
    ).toBeGreaterThan(1);
  });

  it('ask for the connection list every five seconds', async () => {
    await openDashboard();

    expect(subscribedPaths()).toEqual(['/traffic', '/connections']);
    const connections = new URL(mocks.subscribe.mock.calls[1][0]);
    expect(connections.searchParams.get('interval')).toBe('5000');
    expect(connections.searchParams.get('token')).toBe('secret');
  });

  it('close ten seconds after another tab of the page is chosen, and only their own', async () => {
    const page = await openDashboard();

    page.switchTo('sections');
    await vi.advanceTimersByTimeAsync(9999);
    expect(mocks.disconnect).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);
    expect(mocks.disconnect.mock.calls.map(([url]) => url)).toEqual(
      mocks.subscribe.mock.calls.map(([url]) => url),
    );
    expect(mocks.resetAll).not.toHaveBeenCalled();
  });

  it('stay open through a look at another tab shorter than that', async () => {
    const page = await openDashboard();

    page.switchTo('monitoring');
    await vi.advanceTimersByTimeAsync(5000);
    page.switchTo('dashboard');
    await vi.advanceTimersByTimeAsync(60000);

    expect(mocks.disconnect).not.toHaveBeenCalled();
    expect(mocks.subscribe).toHaveBeenCalledTimes(2);
  });

  it('close ten seconds after the page is hidden and open again when it is shown', async () => {
    await openDashboard();

    setVisibility('hidden');
    await vi.advanceTimersByTimeAsync(10000);
    expect(mocks.disconnect).toHaveBeenCalledTimes(2);

    setVisibility('visible');
    await vi.advanceTimersByTimeAsync(0);
    expect(subscribedPaths()).toEqual([
      '/traffic',
      '/connections',
      '/traffic',
      '/connections',
    ]);
  });
});

function reading(started: number, clockMs: number, cpuTicks: number) {
  return {
    success: true,
    data: {
      running: true,
      started,
      cpu_ticks: cpuTicks,
      memory_kb: 25000,
      cpus: 2,
      clock_ms: clockMs,
    },
  };
}

describe('the core widgets', () => {
  it('count the age from one start per core and the load between two readings of it', async () => {
    mocks.readCoreUsage
      .mockResolvedValueOnce(reading(100000, 1_060_000, 500))
      .mockResolvedValueOnce(reading(100000, 1_060_500, 520))
      .mockResolvedValueOnce(reading(100000, 1_062_600, 620))
      .mockResolvedValueOnce(reading(200000, 2_005_000, 30))
      .mockResolvedValueOnce(reading(200000, 2_005_500, 40));
    await openDashboard();
    const { store } = await import('../../../services/store.service');
    const usage = () => store.get().coreUsageWidget;

    const firstStart = Date.now() - 60000;
    expect(usage()).toEqual({
      loading: false,
      failed: false,
      data: { cpu: null, memory: 25_600_000, startedAt: firstStart },
    });

    await vi.advanceTimersByTimeAsync(499);
    expect(usage().data.cpu).toBeNull();
    await vi.advanceTimersByTimeAsync(1);
    expect(usage().data.startedAt).toBe(firstStart);
    expect(usage().data.cpu).toBeCloseTo(20, 2);

    await vi.advanceTimersByTimeAsync(1999);
    expect(usage().data.cpu).toBeCloseTo(20, 2);
    await vi.advanceTimersByTimeAsync(1);
    expect(usage().data.cpu).toBeCloseTo(23.81, 2);

    await vi.advanceTimersByTimeAsync(2000);
    expect(usage().data).toEqual({
      cpu: null,
      memory: 25_600_000,
      startedAt: Date.now() - 5000,
    });

    await vi.advanceTimersByTimeAsync(500);
    expect(usage().data.cpu).toBeCloseTo(10, 2);
  });

  it('say the core is unavailable while it is not running', async () => {
    mocks.readCoreUsage.mockResolvedValue({
      success: true,
      data: { running: false },
    });
    await openDashboard();
    const { store } = await import('../../../services/store.service');

    expect(store.get().coreUsageWidget).toMatchObject({
      loading: false,
      failed: true,
    });
  });
});
