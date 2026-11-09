// A tab keeps its live updates this long out of view, so a quick look elsewhere does not start
// them over.
export const TAB_HIDDEN_GRACE_MS = 10000;

// update() is called whenever shown() may have changed.
export function createTabLifecycle(options: {
  shown: () => boolean;
  start: () => void;
  stop: () => void;
  graceMs?: number;
}) {
  const graceMs = options.graceMs ?? TAB_HIDDEN_GRACE_MS;
  let running = false;
  let stopTimer: ReturnType<typeof setTimeout> | null = null;

  const cancelStop = () => {
    if (stopTimer) {
      clearTimeout(stopTimer);
      stopTimer = null;
    }
  };

  return {
    update() {
      if (options.shown()) {
        cancelStop();
        if (!running) {
          running = true;
          options.start();
        }
        return;
      }

      if (!running || stopTimer) {
        return;
      }

      stopTimer = setTimeout(() => {
        stopTimer = null;
        if (!options.shown()) {
          running = false;
          options.stop();
        }
      }, graceMs);
    },
  };
}
