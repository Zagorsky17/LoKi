import { afterEach, describe, expect, it, vi } from 'vitest';

import { alignLuciRpcTimeout } from '../alignLuciRpcTimeout';

function stubLuci(env?: { rpctimeout?: number }) {
  const luci = { env };
  vi.stubGlobal('L', luci);
  return luci;
}

describe('alignLuciRpcTimeout', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('raises the LuCI transport ceiling above the requested timeout', () => {
    const luci = stubLuci({});

    alignLuciRpcTimeout(180000);

    expect(luci.env?.rpctimeout).toBe(185);
  });

  it('keeps a ceiling that already covers the requested timeout', () => {
    const luci = stubLuci({ rpctimeout: 600 });

    alignLuciRpcTimeout(15000);

    expect(luci.env?.rpctimeout).toBe(600);
  });

  it('never lowers the ceiling for short timeouts', () => {
    const luci = stubLuci({});

    alignLuciRpcTimeout(3000);

    expect(luci.env?.rpctimeout).toBeUndefined();
  });

  it('does nothing without a LuCI environment', () => {
    const luci = stubLuci(undefined);

    expect(() => alignLuciRpcTimeout(120000)).not.toThrow();
    expect(luci.env).toBeUndefined();
  });
});
