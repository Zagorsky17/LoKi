import { describe, expect, it, vi } from 'vitest';

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

const listeners: Record<string, () => void> = {};
const page = { visibilityState: 'visible' };
vi.stubGlobal('document', {
  get visibilityState() {
    return page.visibilityState;
  },
  addEventListener: (type: string, listener: () => void) => {
    listeners[type] = listener;
  },
});
vi.stubGlobal('window', {
  setTimeout: (fn: () => void, ms: number) => setTimeout(fn, ms),
  clearTimeout: (id: ReturnType<typeof setTimeout>) => clearTimeout(id),
  addEventListener: () => {},
});

const { registerRuntimeStateResumeRefresh, startRuntimeUiStatePolling } =
  await import('../runtimeUiState.service');

function state(revision: number) {
  return {
    revision,
    service: {
      forkop: { running: 1, enabled: 1, status: 'running & enabled' },
      sing_box: { running: 1, enabled: 0, status: 'running but disabled' },
    },
    capabilities: {},
    actions: { service: [] },
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('the state wait loop', () => {
  it('keeps waiting after the tab is hidden and shown again before its request returns', async () => {
    const parked: ((value: unknown) => void)[] = [];
    mocks.callUbus.mockImplementation(({ method }: { method: string }) =>
      method === 'state_wait'
        ? new Promise((resolve) => parked.push(resolve))
        : Promise.resolve({ success: true, data: state(1) }),
    );

    registerRuntimeStateResumeRefresh();
    startRuntimeUiStatePolling();
    await settle();
    expect(parked).toHaveLength(1);

    page.visibilityState = 'hidden';
    listeners.visibilitychange();
    page.visibilityState = 'visible';
    listeners.visibilitychange();
    await settle();

    parked[0]({ success: true, data: state(2) });
    await settle();

    const waits = mocks.callUbus.mock.calls.filter(
      (call) => (call[0] as { method: string }).method === 'state_wait',
    );
    expect(waits).toHaveLength(2);
    expect(waits[1][0]).toMatchObject({
      params: { revision: 2 },
      nobatch: true,
    });
  });
});
