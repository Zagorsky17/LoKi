import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import type { Forkop } from '../../../types';
import type { StoreService, StoreType } from '../../../services/store.service';

const CHECK_ORDER = ['SERVICE', 'DNS', 'TRAFFIC', 'SECTIONS'];

const mocks = vi.hoisted(() => {
  const runnerCalls: string[] = [];
  let releaseRunningCheck: (() => void) | null = null;
  let runActionClick: (() => void) | null = null;
  let reportOffered = false;

  return {
    runnerCalls,
    createCheckRunner: (code: string) => async () => {
      runnerCalls.push(code);

      await new Promise<void>((resolve) => {
        releaseRunningCheck = resolve;
      });

      const result = { state: 'success', description: 'OK', items: [] };
      return code === 'SERVICE' ? { result, running: true } : result;
    },
    reset() {
      runnerCalls.length = 0;
      releaseRunningCheck = null;
    },
    finishRunningCheck() {
      const release = releaseRunningCheck;

      releaseRunningCheck = null;
      release?.();
    },
    isCheckRunning: () => releaseRunningCheck !== null,
    clickRunAction: () => runActionClick?.(),
    isReportOffered: () => reportOffered,
    renderRunAction: (props: { click: () => void; report: unknown }) => {
      runActionClick = props.click;
      reportOffered = props.report !== null;
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
  renderCheckSection: mocks.renderStub,
  renderRunAction: mocks.renderRunAction,
  renderSystemInfo: mocks.renderStub,
}));

vi.mock('../checks/service', () => ({
  runServiceCheck: mocks.createCheckRunner('SERVICE'),
}));
vi.mock('../checks/dns', () => ({
  runDnsCheck: mocks.createCheckRunner('DNS'),
}));
vi.mock('../checks/traffic', () => ({
  runTrafficCheck: mocks.createCheckRunner('TRAFFIC'),
}));
vi.mock('../checks/sections', () => ({
  runSectionsCheck: mocks.createCheckRunner('SECTIONS'),
}));

let store: StoreService<StoreType>;

function flush() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function showTab(tab: string) {
  store.set({ tabService: { current: tab, all: [] } });
  await flush();
}

function getCheckState(code: string) {
  return store.get().diagnosticsChecks.find((check) => check.code === code)
    ?.state;
}

function getCheckStates() {
  return store
    .get()
    .diagnosticsChecks.map((check) => check.state)
    .join(',');
}

describe('diagnostic run lifecycle', () => {
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
    await flush();
  });

  beforeEach(async () => {
    mocks.reset();
    await showTab('dashboard');
  });

  it('keeps one pass and its progress across tab switches', async () => {
    await showTab('diagnostic');
    mocks.clickRunAction();
    await flush();

    expect(mocks.runnerCalls).toEqual(['SERVICE']);

    for (let switches = 0; switches < 3; switches += 1) {
      await showTab('dashboard');
      await showTab('diagnostic');
    }

    expect(mocks.runnerCalls).toEqual(['SERVICE']);
    expect(store.get().diagnosticsRunAction.loading).toBe(true);
    expect(getCheckState('SERVICE')).toBe('loading');

    for (let index = 0; index < CHECK_ORDER.length; index += 1) {
      expect(mocks.runnerCalls[index]).toBe(CHECK_ORDER[index]);
      mocks.finishRunningCheck();
      await flush();
    }

    expect(mocks.runnerCalls).toEqual(CHECK_ORDER);
    expect(mocks.isCheckRunning()).toBe(false);
    expect(store.get().diagnosticsRunAction.loading).toBe(false);
  });

  it('shows the result of a pass that finished on another tab', async () => {
    await showTab('diagnostic');
    mocks.clickRunAction();
    await flush();
    await showTab('dashboard');

    while (mocks.isCheckRunning()) {
      mocks.finishRunningCheck();
      await flush();
    }

    expect(mocks.runnerCalls).toEqual(CHECK_ORDER);

    await showTab('diagnostic');

    expect(getCheckState('SECTIONS')).toBe('success');
    expect(mocks.runnerCalls).toEqual(CHECK_ORDER);

    await showTab('dashboard');

    expect(getCheckStates()).toBe('skipped,skipped,skipped,skipped');
  });

  it('offers the report of a run once the run finished, and only while its result stands', async () => {
    await showTab('diagnostic');
    expect(mocks.isReportOffered()).toBe(false);

    mocks.clickRunAction();
    await flush();
    expect(mocks.isReportOffered()).toBe(false);

    while (mocks.isCheckRunning()) {
      mocks.finishRunningCheck();
      await flush();
      expect(mocks.isReportOffered()).toBe(!mocks.isCheckRunning());
    }
    expect(mocks.isReportOffered()).toBe(true);

    await showTab('dashboard');
    await showTab('diagnostic');
    expect(mocks.isReportOffered()).toBe(false);
  });

  it('omits the sections check when no sections are configured, idle or running', async () => {
    const capabilities = mocks.uiState.capabilities;
    mocks.uiState.capabilities = {
      sections_enabled_count: 0,
    };
    const codes = () =>
      store.get().diagnosticsChecks.map((check) => check.code);

    await showTab('diagnostic');
    mocks.clickRunAction();
    await flush();
    while (mocks.isCheckRunning()) {
      mocks.finishRunningCheck();
      await flush();
    }

    expect(mocks.runnerCalls).toEqual(['SERVICE', 'DNS', 'TRAFFIC']);
    expect(codes()).not.toContain('SECTIONS');

    await showTab('dashboard');
    expect(codes()).toEqual(['SERVICE', 'DNS', 'TRAFFIC']);

    mocks.uiState.capabilities = capabilities;
  });
});
