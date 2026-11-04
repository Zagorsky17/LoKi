import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { LokiShellMethods } from '..';

describe('diagnostic checks', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '{}',
      stderr: '',
      code: 0,
    });
  });

  it.each([
    ['checkService', 'check_service'],
    ['checkDns', 'check_dns'],
    ['checkTraffic', 'check_traffic'],
  ] as const)(
    '%s waits long enough for a slow router',
    async (method, command) => {
      await LokiShellMethods[method]();

      const call = mocks.executeShellCommand.mock.calls[0][0];

      expect(call.args[0]).toBe(command);
      expect(call.timeout).toBeGreaterThan(20000);
    },
  );

  it('sends the checks the page ran along with the report, for the router to mask', async () => {
    await LokiShellMethods.report(true, '✓ Service — OK\n');

    const call = mocks.executeShellCommand.mock.calls[0][0];

    expect(call.args).toEqual(['report', 'masked', '✓ Service — OK\n']);
    expect(call.timeout).toBeGreaterThan(20000);
  });

  it('keeps short-lived UI state polling fast', async () => {
    await LokiShellMethods.getUiState();

    expect(mocks.executeShellCommand.mock.calls[0][0].timeout).toBe(3000);
  });
});
