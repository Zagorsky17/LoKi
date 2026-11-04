import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ callUbus: vi.fn() }));

vi.mock('../../../helpers/callUbus', () => ({
  callUbus: mocks.callUbus,
}));

async function freshFeed() {
  vi.resetModules();
  return import('../lokiLogFeed.service');
}

const gone = { success: false, message: 'Object not found', unavailable: true };

beforeEach(() => {
  mocks.callUbus.mockReset();
});

describe('the log feed', () => {
  it('starts from where the log stands and takes only the lines after it', async () => {
    mocks.callUbus.mockResolvedValue({ success: true, data: { cursor: 3 } });
    const feed = await freshFeed();

    const lines: string[] = [];
    feed.startLokiLogFeed((line) => lines.push(line));
    feed.takeLokiLogLines({ cursor: 3, lines: ['loki: old'] });
    await feed.placeLokiLogFeed();
    feed.takeLokiLogLines({ cursor: 4, lines: ['loki: new'] });

    expect(lines).toEqual(['loki: new']);
    expect(feed.getLokiLogCursor()).toBe(4);
  });

  it('goes on from the cursor of the page it took over from', async () => {
    const feed = await freshFeed();

    feed.startLokiLogFeed(() => {}, 7);
    await feed.placeLokiLogFeed();

    expect(feed.getLokiLogCursor()).toBe(7);
    expect(mocks.callUbus).not.toHaveBeenCalled();
  });

  it('asks where the log stands again once the state service is back', async () => {
    mocks.callUbus
      .mockResolvedValueOnce(gone)
      .mockResolvedValueOnce({ success: true, data: { cursor: 5 } });
    const feed = await freshFeed();

    feed.startLokiLogFeed(() => {});
    await feed.placeLokiLogFeed();
    expect(feed.getLokiLogCursor()).toBeUndefined();

    await feed.placeLokiLogFeed();
    expect(feed.getLokiLogCursor()).toBe(5);
  });
});
