import { beforeEach, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ callUbus: vi.fn() }));
vi.mock('../../../../../helpers/callUbus', () => ({
  callUbus: mocks.callUbus,
}));

const ID = 'a'.repeat(64);
const HEADERS = ['User-Agent: sing-box/1.14.4', 'X-HWID: router-test-device'];

beforeEach(() => {
  vi.resetModules();
  mocks.callUbus.mockReset().mockImplementation(({ method }) => ({
    success: true,
    data: method.endsWith('_prepare')
      ? { success: true, id: ID }
      : method.endsWith('_result')
        ? { success: true }
        : { code: 0, stdout: JSON.stringify(HEADERS), stderr: '' },
  }));
  (globalThis as unknown as { fs: unknown }).fs = {
    exec: vi.fn().mockRejectedValue(new Error('Permission denied')),
  };
});

it('loads device headers through the authorized broker without a file exec grant', async () => {
  const { loadDefaultSubscriptionHeaders } = await import('../model');
  expect(await loadDefaultSubscriptionHeaders()).toEqual(HEADERS);
  expect(await loadDefaultSubscriptionHeaders()).toEqual(HEADERS);
  expect(fs.exec).not.toHaveBeenCalled();
  expect(mocks.callUbus).toHaveBeenCalledWith(
    expect.objectContaining({
      method: 'rpc_write_prepare',
      params: { argv: ['get_subscription_default_headers'] },
    }),
  );
  expect(mocks.callUbus).toHaveBeenCalledTimes(3);
});

it('keeps the backend refusal reason and allows a later header load to retry', async () => {
  mocks.callUbus.mockResolvedValueOnce({
    success: true,
    data: {
      success: false,
      message: 'The private RPC journal is unavailable',
    },
  });
  const { loadDefaultSubscriptionHeaders } = await import('../model');
  await expect(loadDefaultSubscriptionHeaders()).rejects.toThrow(
    'The private RPC journal is unavailable',
  );
  expect(await loadDefaultSubscriptionHeaders()).toEqual(HEADERS);
});
