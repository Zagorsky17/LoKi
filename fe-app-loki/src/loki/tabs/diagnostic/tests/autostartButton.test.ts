import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import type { Loki } from '../../../types';
import type { StoreService, StoreType } from '../../../services/store.service';

interface ActionProps {
  loading: boolean;
  visible: boolean;
  onClick: () => void;
}

const mocks = vi.hoisted(() => {
  const frames: string[] = [];
  let recording = false;
  let latest: { enable: ActionProps; disable: ActionProps } | null = null;

  return {
    frames,
    startRecording() {
      recording = true;
      frames.length = 0;
    },
    latestActions: () => latest,
    refreshRuntimeUiStateNow: vi.fn(async () => undefined),
    showToast: vi.fn(),
    enable: vi.fn(async () => ({ success: true, data: undefined })),
    disable: vi.fn(async () => ({ success: true, data: undefined })),
    renderStub: () => ({}),
    renderAvailableActions: (props: {
      enable: ActionProps;
      disable: ActionProps;
    }) => {
      latest = props;

      if (recording) {
        const shown = [
          ['enable', props.enable] as const,
          ['disable', props.disable] as const,
        ]
          .filter(([, action]) => action.visible)
          .map(
            ([name, action]) => `${name}:${action.loading ? 'busy' : 'idle'}`,
          )
          .join('+');

        if (frames[frames.length - 1] !== shown) {
          frames.push(shown);
        }
      }

      return {};
    },
    uiState: {
      service: {},
      capabilities: {},
      actions: { service: [] },
    } as unknown as Loki.UiState,
  };
});

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
  refreshRuntimeUiStateNow: mocks.refreshRuntimeUiStateNow,
  subscribeRuntimeUiState: () => () => {},
  setLocalServiceAction: () => {},
}));

vi.mock('../../../services/systemInfo.service', () => ({
  ensureSystemInfo: async () => ({}),
}));

vi.mock('../../../methods', () => ({
  LokiShellMethods: {
    enable: mocks.enable,
    disable: mocks.disable,
  },
  CustomLokiMethods: {},
}));

vi.mock('../partials', () => ({
  renderAvailableActions: mocks.renderAvailableActions,
  renderCheckSection: mocks.renderStub,
  renderRunAction: mocks.renderStub,
  renderSystemInfo: mocks.renderStub,
}));

let store: StoreService<StoreType>;

function flush() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function publishAutostart(enabled: number) {
  store.set({
    serviceState: {
      loading: false,
      failed: false,
      data: {
        singbox: 1,
        lokiRunning: 1,
        lokiEnabled: enabled,
        lokiBusy: null,
      },
    },
  });
}

describe('autostart button', () => {
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

  beforeEach(() => {
    mocks.enable.mockClear();
    mocks.disable.mockClear();
    mocks.showToast.mockClear();
    mocks.refreshRuntimeUiStateNow.mockReset();
    mocks.refreshRuntimeUiStateNow.mockResolvedValue(undefined);
  });

  it('holds the spinner until the opposite button is the one on the row', async () => {
    publishAutostart(0);
    await flush();
    mocks.refreshRuntimeUiStateNow.mockImplementation(async () => {
      publishAutostart(1);
      return undefined;
    });

    mocks.startRecording();
    mocks.latestActions()!.enable.onClick();
    await flush();

    expect(mocks.enable).toHaveBeenCalledOnce();
    expect(mocks.frames).toEqual(['enable:busy', 'disable:idle']);
  });

  it('does the same in the other direction', async () => {
    publishAutostart(1);
    await flush();
    mocks.refreshRuntimeUiStateNow.mockImplementation(async () => {
      publishAutostart(0);
      return undefined;
    });

    mocks.startRecording();
    mocks.latestActions()!.disable.onClick();
    await flush();

    expect(mocks.disable).toHaveBeenCalledOnce();
    expect(mocks.frames).toEqual(['disable:busy', 'enable:idle']);
    expect(mocks.showToast).not.toHaveBeenCalled();
  });

  it('says so when the switch did not move', async () => {
    publishAutostart(0);
    await flush();
    mocks.enable.mockResolvedValueOnce({ success: false, data: undefined });

    mocks.latestActions()!.enable.onClick();
    await flush();

    expect(mocks.showToast).toHaveBeenCalledWith(
      'Could not enable autostart',
      'error',
    );
  });
});
