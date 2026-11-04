import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getSystemInfo: vi.fn(),
}));

vi.mock('../../methods', () => ({
  LokiShellMethods: {
    getSystemInfo: mocks.getSystemInfo,
  },
}));

import { store } from '../store.service';
import { ensureSystemInfo } from '../systemInfo.service';

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });

  return { promise, resolve };
}

function systemInfoResponse(singBoxVersion: string) {
  return {
    success: true,
    data: {
      loki_version: '1.0.5',
      sing_box_version: singBoxVersion,
    },
  };
}

describe('ensureSystemInfo', () => {
  beforeEach(() => {
    mocks.getSystemInfo.mockReset();
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        loading: false,
        loaded: false,
      },
    });
  });

  it('gives concurrent callers one shared request', async () => {
    const pending = deferred<ReturnType<typeof systemInfoResponse>>();
    mocks.getSystemInfo.mockReturnValue(pending.promise);

    const prefetch = ensureSystemInfo();
    const tab = ensureSystemInfo();

    pending.resolve(systemInfoResponse('1.13.18-extended-2.6.5-f70'));
    const [fromPrefetch, fromTab] = await Promise.all([prefetch, tab]);

    expect(mocks.getSystemInfo).toHaveBeenCalledTimes(1);
    expect(fromPrefetch.sing_box_version).toBe('1.13.18-extended-2.6.5-f70');
    expect(fromTab.sing_box_version).toBe('1.13.18-extended-2.6.5-f70');
  });

  it('serves a later caller from what the first one loaded', async () => {
    mocks.getSystemInfo.mockResolvedValue(systemInfoResponse('1.13.18'));

    await ensureSystemInfo();
    const second = await ensureSystemInfo();

    expect(mocks.getSystemInfo).toHaveBeenCalledTimes(1);
    expect(second.sing_box_version).toBe('1.13.18');
    expect(second.loaded).toBe(true);
  });

  it('still refetches when a caller explicitly forces it', async () => {
    mocks.getSystemInfo.mockResolvedValue(systemInfoResponse('1.13.18'));

    await ensureSystemInfo();
    await ensureSystemInfo({ force: true });

    expect(mocks.getSystemInfo).toHaveBeenCalledTimes(2);
  });
});
