import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
  callUbus: vi.fn(),
}));

vi.mock('../../../helpers/executeShellCommand', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));
vi.mock('../../../helpers/callUbus', () => ({
  callUbus: mocks.callUbus,
}));

import { Loki } from '../../types';
import { store } from '../store.service';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  resetRuntimeUiStateTransport,
  subscribeRuntimeUiState,
} from '../runtimeUiState.service';

function createUiState(
  status = 'running & enabled',
  running = 1,
): Loki.UiState {
  return {
    service: {
      loki: {
        running,
        enabled: 1,
        status,
      },
      sing_box: {
        running,
        enabled: 0,
        status: running ? 'running but disabled' : 'stopped & disabled',
      },
    },
    capabilities: {
      sections_enabled_count: 0,
    },
    actions: {
      service: [],
    },
  };
}

describe('runtime state transport', () => {
  beforeEach(() => {
    store.reset();
    mocks.executeShellCommand.mockReset();
    mocks.callUbus.mockReset();
    resetRuntimeUiStateTransport();
  });

  it('prefers the state service and never reaches for the CLI', async () => {
    const uiState = createUiState('running & enabled', 1);
    mocks.callUbus.mockResolvedValue({
      success: true,
      data: { ...uiState, revision: 7 },
    });

    await expect(refreshRuntimeUiState({ force: true })).resolves.toEqual(
      uiState,
    );

    expect(mocks.callUbus).toHaveBeenCalledWith(
      expect.objectContaining({ object: 'loki', method: 'refresh' }),
    );
    expect(mocks.executeShellCommand).not.toHaveBeenCalled();
  });

  it('asks for a recomputed state only when the read is forced', async () => {
    mocks.callUbus.mockResolvedValue({
      success: true,
      data: { ...createUiState(), revision: 3 },
    });

    await refreshRuntimeUiState();
    await refreshRuntimeUiState({ force: true });

    const methods = mocks.callUbus.mock.calls.map(
      (call) => (call[0] as { method: string }).method,
    );
    expect(methods).toEqual(['state', 'refresh']);
  });

  it('falls back to the CLI when the state service is not there', async () => {
    mocks.callUbus.mockResolvedValue({
      success: false,
      message: 'Object not found',
      unavailable: true,
    });
    const uiState = createUiState('stopped but enabled', 0);
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await expect(refreshRuntimeUiState({ force: true })).resolves.toEqual(
      uiState,
    );
    expect(mocks.executeShellCommand).toHaveBeenCalledOnce();
  });

  it('asks again, after a while, for a service it has found missing', async () => {
    const now = vi.spyOn(Date, 'now').mockReturnValue(1_000_000);
    mocks.callUbus.mockResolvedValue({
      success: false,
      message: 'Object not found',
      unavailable: true,
    });
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(createUiState()),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });
    await refreshRuntimeUiState({ force: true });
    expect(mocks.callUbus).toHaveBeenCalledOnce();
    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(2);

    mocks.callUbus.mockResolvedValue({
      success: true,
      data: { ...createUiState(), revision: 4 },
    });
    now.mockReturnValue(1_031_000);
    await refreshRuntimeUiState({ force: true });
    expect(mocks.callUbus).toHaveBeenCalledTimes(2);
    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(2);
    now.mockRestore();
  });

  it('comes back to the state service after a first call that timed out', async () => {
    const now = vi.spyOn(Date, 'now').mockReturnValue(2_000_000);
    mocks.callUbus.mockResolvedValueOnce({
      success: false,
      message: 'timeout',
      unavailable: false,
    });
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(createUiState()),
      stderr: '',
      code: 0,
    });
    await refreshRuntimeUiState({ force: true });

    mocks.callUbus.mockResolvedValue({
      success: true,
      data: { ...createUiState(), revision: 5 },
    });
    now.mockReturnValue(2_031_000);
    await refreshRuntimeUiState({ force: true });
    expect(mocks.callUbus).toHaveBeenCalledTimes(2);
    now.mockRestore();
  });

  it('keeps using the state service when a call fails without being missing', async () => {
    mocks.callUbus.mockResolvedValueOnce({
      success: true,
      data: { ...createUiState(), revision: 1 },
    });
    await refreshRuntimeUiState({ force: true });

    mocks.callUbus.mockResolvedValueOnce({
      success: false,
      message: 'timeout',
      unavailable: false,
    });
    await expect(
      refreshRuntimeUiState({ force: true }),
    ).resolves.toBeUndefined();

    expect(mocks.executeShellCommand).not.toHaveBeenCalled();
  });
});

describe('refreshRuntimeUiState', () => {
  beforeEach(() => {
    store.reset();
    mocks.executeShellCommand.mockReset();
    mocks.callUbus.mockReset();
    mocks.callUbus.mockResolvedValue({
      success: false,
      message: 'Object not found',
      unavailable: true,
    });
  });

  it('applies current UI state to the shared store', async () => {
    const uiState = createUiState('stopped but enabled', 0);

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await expect(refreshRuntimeUiState({ force: true })).resolves.toEqual(
      uiState,
    );

    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/loki',
      args: ['get_ui_state'],
      timeout: 3000,
    });
    expect(store.get().serviceState.data).toMatchObject({
      lokiRunning: 0,
      lokiEnabled: 1,
    });
  });

  it('coalesces concurrent refreshes into one RPC call', async () => {
    const uiState = createUiState();
    let resolveRpc: (value: {
      stdout: string;
      stderr: string;
      code: number;
    }) => void = () => undefined;

    mocks.executeShellCommand.mockReturnValue(
      new Promise((resolve) => {
        resolveRpc = resolve;
      }),
    );

    const firstRefresh = refreshRuntimeUiState({ force: true });
    const secondRefresh = refreshRuntimeUiState({ force: true });

    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(1);

    resolveRpc({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await expect(Promise.all([firstRefresh, secondRefresh])).resolves.toEqual([
      uiState,
      uiState,
    ]);
  });

  it('notifies subscribers after applying fresh state', async () => {
    const uiState = createUiState('stopped but enabled', 0);
    const listener = vi.fn();
    const unsubscribe = subscribeRuntimeUiState(listener);
    listener.mockClear();

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });

    expect(listener).toHaveBeenCalledWith(uiState);

    unsubscribe();
    listener.mockClear();

    await refreshRuntimeUiState({ force: true });

    expect(listener).not.toHaveBeenCalled();
  });

  it('replays cached state to a new subscriber without another RPC', async () => {
    const uiState = createUiState('starting', 0);

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });

    const listener = vi.fn();
    const unsubscribe = subscribeRuntimeUiState(listener);

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenCalledWith(uiState);
    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(1);

    unsubscribe();
  });

  it('exposes the cached state without another RPC', async () => {
    const uiState = createUiState('running & enabled', 1);

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });
    mocks.executeShellCommand.mockClear();

    expect(getCachedRuntimeUiState()).toEqual(uiState);
    expect(mocks.executeShellCommand).not.toHaveBeenCalled();
  });
});
