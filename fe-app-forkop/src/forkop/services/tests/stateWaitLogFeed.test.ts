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

vi.stubGlobal('document', {
  visibilityState: 'visible',
  addEventListener: () => {},
});
vi.stubGlobal('window', {
  setTimeout: (fn: () => void, ms: number) => setTimeout(fn, ms),
  clearTimeout: (id: ReturnType<typeof setTimeout>) => clearTimeout(id),
  addEventListener: () => {},
});

const { startRuntimeUiStatePolling } = await import(
  '../runtimeUiState.service'
);
const { startForkopLogFeed } = await import('../forkopLogFeed.service');

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

describe('the state wait and the log feed', () => {
  it('share one parked request, which hands the new lines to the feed', async () => {
    const parked: ((value: unknown) => void)[] = [];
    mocks.callUbus.mockImplementation(({ method }: { method: string }) => {
      if (method === 'refresh') {
        return Promise.resolve({ success: true, data: state(1) });
      }
      if (method === 'logs') {
        return Promise.resolve({ success: true, data: { cursor: 3 } });
      }
      return new Promise((resolve) => parked.push(resolve));
    });

    const lines: string[] = [];
    startForkopLogFeed((line) => lines.push(line));
    startRuntimeUiStatePolling();
    await settle();

    parked[0]({
      success: true,
      data: { ...state(1), cursor: 4, lines: ['forkop: [error] x'] },
    });
    await settle();

    const methods = mocks.callUbus.mock.calls.map(
      (call) => (call[0] as { method: string }).method,
    );
    const waits = mocks.callUbus.mock.calls
      .filter((call) => (call[0] as { method: string }).method === 'state_wait')
      .map((call) => call[0]);
    expect(methods).not.toContain('logs_wait');
    expect(lines).toEqual(['forkop: [error] x']);
    expect(waits).toEqual([
      expect.objectContaining({
        params: { revision: 1, cursor: 3 },
        nobatch: true,
      }),
      expect.objectContaining({ params: { revision: 1, cursor: 4 } }),
    ]);
    expect(parked).toHaveLength(2);
  });
});
