import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import type { Forkop } from '../../../types';

const mocks = vi.hoisted(() => ({
  showToast: vi.fn(),
  uiActionAck: vi.fn(async () => ({ success: true, data: undefined })),
  serviceActionStart: vi.fn(async () => ({
    success: false,
    error: 'Another service action is already running',
  })),
  listener: null as ((state: Forkop.UiState) => void) | null,
  actions: null as Record<string, { onClick: () => void }> | null,
  uiState: {
    service: {},
    capabilities: {},
    actions: { service: [] },
  } as unknown as Forkop.UiState,
}));

vi.mock('../../../../helpers/showToast', () => ({
  showToast: mocks.showToast,
}));
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
  refreshRuntimeUiStateNow: async () => undefined,
  subscribeRuntimeUiState: (listener: (state: Forkop.UiState) => void) => {
    mocks.listener = listener;
    return () => {};
  },
  setLocalServiceAction: () => {},
}));

vi.mock('../../../services/systemInfo.service', () => ({
  ensureSystemInfo: async () => ({}),
}));

vi.mock('../../../methods', () => ({
  ForkopShellMethods: {
    uiActionAck: mocks.uiActionAck,
    serviceActionStart: mocks.serviceActionStart,
  },
  CustomForkopMethods: {},
}));

vi.mock('../partials', () => ({
  renderAvailableActions: (props: Record<string, { onClick: () => void }>) => {
    mocks.actions = props;
    return {};
  },
  renderCheckSection: () => ({}),
  renderRunAction: () => ({}),
  renderSystemInfo: () => ({}),
}));

function flush() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function finished(action: string, success: boolean, jobId: string) {
  return {
    ...mocks.uiState,
    actions: {
      service: [{ action, job_id: jobId, running: false, success }],
    },
  } as unknown as Forkop.UiState;
}

describe('service action alerts', () => {
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

    const { store } = await import('../../../services');
    const { initController } = await import('../initController');

    await initController();
    store.set({
      tabService: { current: 'diagnostic', all: [] },
      serviceState: {
        loading: false,
        failed: false,
        data: {
          singbox: 0,
          forkopRunning: 0,
          forkopEnabled: 1,
          forkopBusy: null,
        },
      },
    });
    await flush();
  });

  beforeEach(() => {
    mocks.showToast.mockClear();
    mocks.uiActionAck.mockClear();
  });

  it('leaves an action that ran and failed to the alert its log raises', async () => {
    for (const [action, jobId] of [
      ['start', 'job-start'],
      ['stop', 'job-stop'],
      ['restart', 'job-restart'],
      ['reload', 'job-reload'],
    ]) {
      mocks.listener!(finished(action, false, jobId));
      await flush();
      expect(mocks.uiActionAck).toHaveBeenLastCalledWith(jobId);
    }

    expect(mocks.showToast).not.toHaveBeenCalled();
  });

  it('says so when an action never became a job', async () => {
    mocks.actions!.start.onClick();
    await flush();

    expect(mocks.showToast).toHaveBeenCalledWith(
      'Failed to start the service',
      'error',
    );
  });
});
