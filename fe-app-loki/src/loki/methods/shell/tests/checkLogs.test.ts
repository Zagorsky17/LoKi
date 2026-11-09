import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
  callUbus: vi.fn(),
}));

vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

vi.mock('../../../../helpers/callUbus', () => ({
  callUbus: mocks.callUbus,
}));

const UNAVAILABLE = { success: false, message: 'gone', unavailable: true };

describe('LokiShellMethods.checkLogs', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
    mocks.callUbus.mockReset();
    vi.resetModules();
  });

  async function methods() {
    return (await import('..')).LokiShellMethods;
  }

  it('reads the whole log from the state service only once a line arrived', async () => {
    const shell = await methods();
    mocks.callUbus
      .mockResolvedValueOnce({ success: true, data: { cursor: 4, text: 'a' } })
      .mockResolvedValueOnce({
        success: true,
        data: { cursor: 4, unchanged: true },
      })
      .mockResolvedValueOnce({
        success: true,
        data: { cursor: 5, text: 'ab' },
      });

    expect(await shell.checkLogs()).toEqual({ success: true, data: 'a' });
    expect(await shell.checkLogs()).toEqual({ success: true, data: 'a' });
    expect(await shell.checkLogs()).toEqual({ success: true, data: 'ab' });
    expect(mocks.callUbus.mock.calls.map(([call]) => call.params)).toEqual([
      {},
      { cursor: 4 },
      { cursor: 4 },
    ]);
    expect(mocks.executeShellCommand).not.toHaveBeenCalled();
  });

  it('runs the CLI when the state service does not answer, and starts over afterwards', async () => {
    const shell = await methods();
    mocks.callUbus
      .mockResolvedValueOnce({ success: true, data: { cursor: 2, text: 'a' } })
      .mockResolvedValueOnce(UNAVAILABLE)
      .mockResolvedValueOnce({ success: true, data: { cursor: 3, text: 'b' } });
    mocks.executeShellCommand.mockResolvedValue({
      stdout: 'from cli',
      stderr: '',
      code: 0,
    });

    await shell.checkLogs();
    expect(await shell.checkLogs()).toEqual({
      success: true,
      data: 'from cli',
    });
    await shell.checkLogs();
    expect(mocks.callUbus.mock.calls[2][0].params).toEqual({});
  });

  it('shares one in-flight log request between UI pollers', async () => {
    const shell = await methods();
    mocks.callUbus.mockResolvedValue(UNAVAILABLE);
    let finishRequest: (value: unknown) => void = () => {};
    mocks.executeShellCommand.mockImplementation(
      () =>
        new Promise((resolve) => {
          finishRequest = resolve;
        }),
    );

    const first = shell.checkLogs();
    const second = shell.checkLogs();
    await vi.waitFor(() =>
      expect(mocks.executeShellCommand).toHaveBeenCalledTimes(1),
    );
    finishRequest({ stdout: 'line', stderr: '', code: 0 });
    await expect(Promise.all([first, second])).resolves.toEqual([
      { success: true, data: 'line' },
      { success: true, data: 'line' },
    ]);
    expect(mocks.callUbus).toHaveBeenCalledTimes(1);
  });

  it('answers an empty log as a log with no lines', async () => {
    const shell = await methods();
    mocks.callUbus.mockResolvedValue(UNAVAILABLE);
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '',
      stderr: '',
      code: 0,
    });

    await expect(shell.checkLogs()).resolves.toEqual({
      success: true,
      data: '',
    });
  });
});
