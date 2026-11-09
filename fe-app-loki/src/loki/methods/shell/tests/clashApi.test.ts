import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { LokiShellMethods } from '..';

describe('LokiShellMethods.clashApi', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
  });

  it('passes the requested method, path and body to the CLI transport', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '{"status":204,"body":""}',
      stderr: '',
      code: 0,
    });

    await expect(
      LokiShellMethods.clashApi(
        'PUT',
        '/proxies/main-out',
        '{"name":"main-subscription-1-provider/Example"}',
      ),
    ).resolves.toEqual({
      success: true,
      data: { status: 204, body: '' },
    });
    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/loki',
      args: [
        'clash_api',
        'PUT',
        '/proxies/main-out',
        '{"name":"main-subscription-1-provider/Example"}',
      ],
      timeout: 65000,
    });
  });

  it('returns the raw Clash API status and body for a GET request', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout:
        '{"status":200,"body":"{\\"url\\":\\"vless://id@example.com:443\\"}"}',
      stderr: '',
      code: 0,
    });

    await expect(
      LokiShellMethods.clashApi(
        'GET',
        '/proxies/main-subscription-1-provider%2FExample/link',
      ),
    ).resolves.toEqual({
      success: true,
      data: {
        status: 200,
        body: '{"url":"vless://id@example.com:443"}',
      },
    });
    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/loki',
      args: [
        'clash_api',
        'GET',
        '/proxies/main-subscription-1-provider%2FExample/link',
        '',
      ],
      timeout: 10000,
    });
  });

  // The router holds a probe through an outbound for its own timeout, past a plain read's budget.
  it('waits out a probe through an outbound like a write', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '{"status":200,"body":"{}"}',
      stderr: '',
      code: 0,
    });

    for (const path of [
      '/proxies/main-out/delay?url=https%3A%2F%2Fexample.com&timeout=5000',
      '/proxies/main-out/exit?timeout=5000',
    ]) {
      await LokiShellMethods.clashApi('GET', path);
      expect(mocks.executeShellCommand).toHaveBeenLastCalledWith(
        expect.objectContaining({ timeout: 65000 }),
      );
    }
  });

  it('reports a transport failure without inventing a status', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '',
      stderr: 'Clash API request failed: GET /proxies',
      code: 1,
    });

    await expect(LokiShellMethods.clashApi('GET', '/proxies')).resolves.toEqual(
      {
        success: false,
        error: 'Clash API request failed: GET /proxies',
      },
    );
  });
});
