import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import type { Forkop } from '../../../types';
import type {
  IDiagnosticsChecksStoreItem,
  StoreService,
  StoreType,
} from '../../../services/store.service';

type Drawn = { expanded?: boolean; onToggle?: () => void };

const mocks = vi.hoisted(() => {
  const drawn = new Map<string, Drawn>();
  let runActionClick: (() => void) | null = null;

  return {
    drawn,
    clickRunAction: () => runActionClick?.(),
    renderRunAction: (props: { click: () => void }) => {
      runActionClick = props.click;
      return {};
    },
    renderCheckSection: (check: { code: string }, options: Drawn) => {
      drawn.set(check.code, options);
      return {};
    },
    renderStub: () => ({}),
    uiState: {
      service: {},
      capabilities: {},
      actions: { service: [] },
    } as unknown as Forkop.UiState,
  };
});

vi.mock('../../../../helpers/onMount', () => ({
  onMount: async () => ({}),
}));
vi.mock('../../../../helpers/preserveScrollForPage', () => ({
  preserveScrollForPage: (renderFn: () => void) => renderFn(),
}));
vi.mock('../../../services', async () => ({
  ...(await import('../../../services/store.service')),
  logger: { debug: () => {}, error: () => {}, info: () => {}, warn: () => {} },
  getCachedRuntimeUiState: () => mocks.uiState,
  refreshRuntimeUiState: async () => mocks.uiState,
  subscribeRuntimeUiState: () => () => {},
  setLocalServiceAction: () => {},
}));
vi.mock('../../../services/systemInfo.service', () => ({
  ensureSystemInfo: async () => ({}),
}));
vi.mock('../../../methods', () => ({
  ForkopShellMethods: {},
  CustomForkopMethods: {},
}));
vi.mock('../partials', () => ({
  renderAvailableActions: mocks.renderStub,
  renderCheckSection: mocks.renderCheckSection,
  renderRunAction: mocks.renderRunAction,
  renderSystemInfo: mocks.renderStub,
}));
vi.mock('../checks/service', () => ({
  runServiceCheck: async () => ({
    result: { state: 'success', description: 'OK', items: [] },
    running: true,
  }),
}));
const passed = { state: 'success', description: 'OK', items: [] };
for (const [module, runner] of [
  ['dns', 'runDnsCheck'],
  ['traffic', 'runTrafficCheck'],
  ['sections', 'runSectionsCheck'],
]) {
  vi.doMock(`../checks/${module}`, () => ({ [runner]: async () => passed }));
}

let store: StoreService<StoreType>;

function flush() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function publishResult() {
  const states: Record<string, IDiagnosticsChecksStoreItem['state']> = {
    SERVICE: 'success',
    DNS: 'error',
    TRAFFIC: 'warning',
  };
  store.set({
    diagnosticsChecks: store.get().diagnosticsChecks.map((check) => ({
      ...check,
      state: states[check.code] || 'success',
      items: [{ state: 'success', key: 'checked', value: '' }],
    })),
  });
}

describe('which checks show their details', () => {
  beforeAll(async () => {
    const element = {
      isConnected: true,
      offsetParent: {},
      replaceChildren() {},
    };
    globalThis.document = {
      getElementById: () => element,
      querySelector: () => null,
    } as unknown as Document;

    ({ store } = await import('../../../services'));
    const { initController } = await import('../initController');
    await initController();
    store.set({ tabService: { current: 'diagnostic', all: [] } });
    await flush();
  });

  beforeEach(async () => {
    mocks.clickRunAction();
    await flush();
    publishResult();
    await flush();
  });

  it('opens a check with a problem and keeps one that passed to a line', () => {
    expect(mocks.drawn.get('DNS')?.expanded).toBe(true);
    expect(mocks.drawn.get('TRAFFIC')?.expanded).toBe(true);
    expect(mocks.drawn.get('SERVICE')?.expanded).toBe(false);
  });

  it('keeps what the reader folded by hand until the next run', async () => {
    mocks.drawn.get('SERVICE')?.onToggle?.();
    mocks.drawn.get('TRAFFIC')?.onToggle?.();
    expect(mocks.drawn.get('SERVICE')?.expanded).toBe(true);
    expect(mocks.drawn.get('TRAFFIC')?.expanded).toBe(false);

    publishResult();
    await flush();
    expect(mocks.drawn.get('SERVICE')?.expanded).toBe(true);

    mocks.clickRunAction();
    await flush();
    publishResult();
    await flush();
    expect(mocks.drawn.get('SERVICE')?.expanded).toBe(false);
    expect(mocks.drawn.get('TRAFFIC')?.expanded).toBe(true);
  });
});
