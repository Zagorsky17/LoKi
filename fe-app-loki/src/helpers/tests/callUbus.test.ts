import { beforeEach, describe, expect, it, vi } from 'vitest';
import { callUbus } from '../callUbus';

type RpcStub = {
  declare: ReturnType<typeof vi.fn>;
};

function stubRpc(call: ReturnType<typeof vi.fn>) {
  const rpc: RpcStub = {
    declare: vi.fn(() => call),
  };
  (globalThis as unknown as { rpc?: unknown }).rpc = rpc;
  return rpc;
}

function notFound() {
  return Object.assign(new Error('Object not found'), { ubus_rpc_status: 4 });
}

beforeEach(() => {
  vi.useRealTimers();
  (globalThis as unknown as { rpc?: unknown }).rpc = undefined;
  (globalThis as unknown as { L?: unknown }).L = { env: {} };
  (globalThis as unknown as { _: (value: string) => string })._ = (value) =>
    value;
});

describe('callUbus', () => {
  it('logs a transport refusal in the browser without request parameters', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    stubRpc(vi.fn().mockRejectedValue(new Error('Permission denied')));
    try {
      await callUbus({
        object: 'loki',
        method: 'rpc_write',
        timeoutMs: 1000,
        retryUnavailable: false,
        params: { token: 'synthetic-private-token' },
      });
      expect(error).toHaveBeenCalledWith(
        '[ERROR]',
        '[RPC]',
        'loki.rpc_write',
        'Permission denied',
      );
      expect(JSON.stringify(error.mock.calls)).not.toContain(
        'synthetic-private-token',
      );
    } finally {
      error.mockRestore();
    }
  });

  it('returns what the object answered', async () => {
    const call = vi.fn().mockResolvedValue({ revision: 3 });
    stubRpc(call);

    await expect(
      callUbus<{ revision: number }>({
        object: 'loki',
        method: 'state',
        timeoutMs: 1000,
      }),
    ).resolves.toEqual({ success: true, data: { revision: 3 } });
  });

  it('waits out a service that is only briefly missing', async () => {
    const call = vi
      .fn()
      .mockRejectedValueOnce(notFound())
      .mockResolvedValueOnce({ revision: 9 });
    stubRpc(call);

    await expect(
      callUbus<{ revision: number }>({
        object: 'loki',
        method: 'state',
        timeoutMs: 1000,
      }),
    ).resolves.toEqual({ success: true, data: { revision: 9 } });
    expect(call).toHaveBeenCalledTimes(2);
  });

  it('gives up on an object that is genuinely not there', async () => {
    const call = vi.fn().mockRejectedValue(notFound());
    stubRpc(call);

    const result = await callUbus({
      object: 'loki',
      method: 'state',
      timeoutMs: 1000,
    });

    expect(result).toMatchObject({ success: false, unavailable: true });
    expect(call).toHaveBeenCalledTimes(3);
  }, 10000);

  it('does not retry a failure that is not an absence', async () => {
    const call = vi.fn().mockRejectedValue(new Error('boom'));
    stubRpc(call);

    const result = await callUbus({
      object: 'loki',
      method: 'state',
      timeoutMs: 1000,
    });

    expect(result).toMatchObject({ success: false, unavailable: false });
    expect(call).toHaveBeenCalledOnce();
  });

  it('keeps a call out of LuCI batches only when asked to', async () => {
    const call = vi.fn().mockResolvedValue({ revision: 3 });
    const rpc = stubRpc(call);

    await callUbus({ object: 'loki', method: 'state', timeoutMs: 1000 });
    await callUbus({
      object: 'loki',
      method: 'state_wait',
      params: { revision: 3 },
      timeoutMs: 1000,
      nobatch: true,
    });

    expect(rpc.declare.mock.calls.map(([options]) => options.nobatch)).toEqual([
      undefined,
      true,
    ]);
  });

  it('reports rpc being absent as an absence, without retrying it', async () => {
    const result = await callUbus({
      object: 'loki',
      method: 'state',
      timeoutMs: 1000,
      retryUnavailable: false,
    });

    expect(result).toMatchObject({ success: false, unavailable: true });
  });
});
