import { describe, expect, it, vi } from 'vitest';

import { closeConnections } from '../closeConnections';

const ok = { success: true as const, data: undefined };
const refused = { success: false as const, error: 'Clash API request failed' };

describe('closing the connections a filter found', () => {
  it('closes every one of them by its id', async () => {
    const close = vi.fn(async (_id: string) => ok);

    expect(await closeConnections(['a', 'b', 'c'], close)).toEqual({
      closed: ['a', 'b', 'c'],
      failed: [],
    });
    expect(close.mock.calls.map(([id]) => id)).toEqual(['a', 'b', 'c']);
  });

  it('keeps the ones it could not close apart', async () => {
    const close = vi.fn(async (id: string) => (id === 'b' ? refused : ok));

    expect(await closeConnections(['a', 'b', 'c'], close)).toEqual({
      closed: ['a', 'c'],
      failed: ['b'],
    });
  });

  it('counts a request that threw as not closed', async () => {
    const close = vi.fn(async (id: string) => {
      if (id === 'a') throw new Error('network');
      return ok;
    });

    expect(await closeConnections(['a', 'b'], close)).toEqual({
      closed: ['b'],
      failed: ['a'],
    });
  });

  it('has no more than two requests in flight and keeps every requested id', async () => {
    let inFlight = 0;
    let most = 0;
    const close = vi.fn(async () => {
      inFlight += 1;
      most = Math.max(most, inFlight);
      await new Promise((resolve) => setTimeout(resolve, 1));
      inFlight -= 1;
      return ok;
    });

    const ids = Array.from({ length: 10 }, (_, index) => `c${index}`);
    const result = await closeConnections(ids, close);

    expect(result.closed).toEqual(ids);
    expect(most).toBe(2);
  });
});
