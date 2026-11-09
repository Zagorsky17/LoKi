import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { createPollChain } from '../pollChain';

let page: { visibilityState: string };
const listeners = new Set<() => void>();

beforeEach(() => {
  vi.useFakeTimers();
  page = { visibilityState: 'visible' };
  listeners.clear();
  vi.stubGlobal('document', {
    get visibilityState() {
      return page.visibilityState;
    },
    addEventListener: (_type: string, listener: () => void) =>
      listeners.add(listener),
    removeEventListener: (_type: string, listener: () => void) =>
      listeners.delete(listener),
  });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function answered() {
  let answer: () => void = () => {};
  const run = vi.fn(
    () =>
      new Promise<void>((resolve) => {
        answer = resolve;
      }),
  );
  return { run, answer: () => answer() };
}

describe('a poll chain', () => {
  it('asks again once the answer is in, after the delay it gives', async () => {
    const { run, answer } = answered();
    const poll = createPollChain(run, () => 1000);

    poll.start(0);
    await vi.advanceTimersByTimeAsync(0);
    expect(run).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(5000);
    expect(run).toHaveBeenCalledTimes(1);

    answer();
    await vi.advanceTimersByTimeAsync(1000);
    expect(run).toHaveBeenCalledTimes(2);
  });

  it('stays one chain across a stop and a start during a request', async () => {
    const { run, answer } = answered();
    const poll = createPollChain(run, () => 1000);

    poll.start(0);
    await vi.advanceTimersByTimeAsync(0);
    poll.stop();
    poll.start(500);
    answer();
    await vi.advanceTimersByTimeAsync(500);
    expect(run).toHaveBeenCalledTimes(2);

    answer();
    await vi.advanceTimersByTimeAsync(999);
    expect(run).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(run).toHaveBeenCalledTimes(3);
  });

  it('asks nothing once stopped', async () => {
    const { run } = answered();
    const poll = createPollChain(run, () => 1000);

    poll.start(100);
    poll.stop();
    await vi.advanceTimersByTimeAsync(10000);

    expect(run).not.toHaveBeenCalled();
  });

  it('waits for a hidden page to come back before asking', async () => {
    const { run } = answered();
    const poll = createPollChain(run, () => 1000);
    page.visibilityState = 'hidden';

    poll.start(0);
    await vi.advanceTimersByTimeAsync(60000);
    expect(run).not.toHaveBeenCalled();

    page.visibilityState = 'visible';
    listeners.forEach((listener) => listener());
    await vi.advanceTimersByTimeAsync(0);
    expect(run).toHaveBeenCalledTimes(1);
  });

  it('asks at once when told to, unless a request is already out', async () => {
    const { run, answer } = answered();
    const poll = createPollChain(run, () => 1000);

    poll.start(5000);
    poll.now();
    await vi.advanceTimersByTimeAsync(0);
    expect(run).toHaveBeenCalledTimes(1);

    poll.now();
    await vi.advanceTimersByTimeAsync(0);
    expect(run).toHaveBeenCalledTimes(1);

    answer();
    await vi.advanceTimersByTimeAsync(1000);
    expect(run).toHaveBeenCalledTimes(2);
  });
});
