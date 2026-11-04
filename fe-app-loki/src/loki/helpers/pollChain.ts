import { whenDocumentVisible } from '../../helpers/isDocumentVisible';

// Asks, waits for the answer, then schedules the next request after nextDelay(). At most one
// request per chain: an answer arriving after a stop schedules nothing, and a request due while
// the page is hidden waits until it is shown.
export function createPollChain(
  run: () => Promise<unknown>,
  nextDelay: () => number,
) {
  let generation = 0;
  let active = false;
  let running = false;
  let timer: ReturnType<typeof setTimeout> | null = null;

  const request = (current: number) => {
    if (current !== generation || running) {
      return;
    }
    running = true;
    void Promise.resolve()
      .then(run)
      .catch(() => undefined)
      .finally(() => {
        running = false;
        if (current === generation) {
          schedule(nextDelay(), current);
        }
      });
  };

  const schedule = (delay: number, current: number) => {
    timer = setTimeout(() => {
      timer = null;
      whenDocumentVisible(() => request(current));
    }, delay);
  };

  const clearTimer = () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
  };

  return {
    get active() {
      return active;
    },

    start(delay: number) {
      if (active) {
        return;
      }
      active = true;
      generation += 1;
      schedule(delay, generation);
    },

    stop() {
      active = false;
      generation += 1;
      running = false;
      clearTimer();
    },

    // A request already on its way finishes and schedules the next one itself.
    now() {
      if (!active || running) {
        return;
      }
      clearTimer();
      schedule(0, generation);
    },
  };
}
