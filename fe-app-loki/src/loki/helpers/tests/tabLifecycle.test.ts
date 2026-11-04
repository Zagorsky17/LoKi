import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { createTabLifecycle } from '../tabLifecycle';

let shown = false;
let start: ReturnType<typeof vi.fn>;
let stop: ReturnType<typeof vi.fn>;

function lifecycle() {
  return createTabLifecycle({
    shown: () => shown,
    start,
    stop,
    graceMs: 10000,
  });
}

beforeEach(() => {
  vi.useFakeTimers();
  shown = false;
  start = vi.fn();
  stop = vi.fn();
});

afterEach(() => {
  vi.useRealTimers();
});

describe('a tab lifecycle', () => {
  it('starts when the tab comes into view, once', () => {
    const tab = lifecycle();

    tab.update();
    expect(start).not.toHaveBeenCalled();

    shown = true;
    tab.update();
    tab.update();
    expect(start).toHaveBeenCalledTimes(1);
  });

  it('stops once the tab has been out of view for the grace period', () => {
    const tab = lifecycle();
    shown = true;
    tab.update();

    shown = false;
    tab.update();
    vi.advanceTimersByTime(9999);
    expect(stop).not.toHaveBeenCalled();

    tab.update();
    vi.advanceTimersByTime(1);
    expect(stop).toHaveBeenCalledTimes(1);
  });

  it('keeps running through a look away shorter than the grace period', () => {
    const tab = lifecycle();
    shown = true;
    tab.update();

    shown = false;
    tab.update();
    vi.advanceTimersByTime(5000);
    shown = true;
    tab.update();
    vi.advanceTimersByTime(60000);

    expect(stop).not.toHaveBeenCalled();
    expect(start).toHaveBeenCalledTimes(1);
  });

  it('starts again when the tab comes back after it stopped', () => {
    const tab = lifecycle();
    shown = true;
    tab.update();
    shown = false;
    tab.update();
    vi.advanceTimersByTime(10000);

    shown = true;
    tab.update();

    expect(stop).toHaveBeenCalledTimes(1);
    expect(start).toHaveBeenCalledTimes(2);
  });

  it('does not stop a tab that is back in view when the grace period ends', () => {
    const tab = lifecycle();
    shown = true;
    tab.update();
    shown = false;
    tab.update();

    shown = true;
    vi.advanceTimersByTime(10000);

    expect(stop).not.toHaveBeenCalled();
  });
});
