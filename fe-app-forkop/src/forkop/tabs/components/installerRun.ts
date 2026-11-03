import { createPollChain } from '../../helpers/pollChain';
import type { Forkop } from '../../types';
import type { InstallerApi } from './installerApi';

const LIVE_POLL_MS = 400;
// Output that arrived is followed by the next read at once: a long run read from its start
// comes in parts.
const CATCH_UP_POLL_MS = 50;
// Out of view a run is followed only to learn its end, which reloads the page.
const BACKGROUND_POLL_MS = 2000;
// Unanswered for this long, the page says the router is out of reach.
const LOST_AFTER_MS = 6000;
// A finished run stays in view this long before the page reloads or leaves.
export const AFTER_RUN_MS = 3000;

export type InstallerAfterRun = 'reload' | 'leave';

export interface InstallerRunState {
  // empty while no run is known
  id: string;
  action: Forkop.InstallerAction | null;
  loaded: boolean;
  starting: boolean;
  running: boolean;
  interactive: boolean;
  exit: number | null;
  interrupted: boolean;
  // a stop was asked, from this page, another one or Ctrl+C in the terminal
  stopping: boolean;
  changed: boolean;
  checkResult?: Forkop.UpdateCheckResult | null;
  // router seconds
  startedAt: number | null;
  finishedAt: number | null;
  log: boolean;
  lost: boolean;
  // what the page does once the run it watched has ended
  after: InstallerAfterRun | null;
}

const INITIAL: InstallerRunState = {
  id: '',
  action: null,
  loaded: false,
  starting: false,
  running: false,
  interactive: false,
  exit: null,
  interrupted: false,
  stopping: false,
  changed: false,
  checkResult: null,
  startedAt: null,
  finishedAt: null,
  log: false,
  lost: false,
  after: null,
};

// A run the page watched end reloads it when the packages changed under it, and leaves it when
// Forkop and its page are gone.
export function afterRun(state: InstallerRunState): InstallerAfterRun | null {
  if (state.action === 'check') {
    return null;
  }
  if (state.action === 'uninstall' && state.exit === 0) {
    return 'leave';
  }
  return state.changed ? 'reload' : null;
}

// Follows the run through the object its process publishes while it lives and through the CLI
// otherwise, keeping the terminal at the byte offset it has shown.
export function createInstallerRun(options: {
  api: Pick<InstallerApi, 'start' | 'status' | 'read' | 'input' | 'stop'>;
  terminal: { write(data: string): void; reset(): void };
  lang: () => string;
  onChange: (state: InstallerRunState) => void;
  onStartFailed: (message: string) => void;
  onAfterRun: (after: InstallerAfterRun) => void;
}) {
  let state: InstallerRunState = { ...INITIAL };
  let offset = 0;
  let hot = false;
  let watched = false;
  let shown = false;
  let catchingUp = false;
  let failingSince: number | null = null;
  // this page asked for a stop the router has not reported yet
  let stopAsked = false;

  const emit = () => options.onChange({ ...state });
  const shouldPoll = () => state.running || (shown && !state.loaded);

  function follow(id: string) {
    if (id !== state.id) {
      options.terminal.reset();
      offset = 0;
      watched = false;
      stopAsked = false;
    }
  }

  function settle() {
    const after = afterRun(state);
    if (!watched || !after) {
      return;
    }
    state.after = after;
    setTimeout(() => options.onAfterRun(after), AFTER_RUN_MS);
  }

  function apply(snapshot: Forkop.InstallerSnapshot) {
    follow(snapshot.id);
    const from = snapshot.offset ?? 0;
    catchingUp = false;
    if (from === offset && snapshot.data) {
      options.terminal.write(snapshot.data);
      offset = snapshot.next ?? offset;
      catchingUp = true;
    } else if (from !== offset) {
      // an answer for another run's offset: this run is read from its start next
      catchingUp = true;
    }

    const wasRunning = state.running && state.id === snapshot.id;
    state = {
      ...state,
      id: snapshot.id,
      action: snapshot.action ?? null,
      loaded: true,
      running: snapshot.running,
      interactive: Boolean(snapshot.interactive),
      exit: snapshot.exit ?? null,
      interrupted: Boolean(snapshot.interrupted),
      stopping: Boolean(snapshot.stop_requested) || stopAsked,
      changed: Boolean(snapshot.changed),
      checkResult: snapshot.check_result ?? null,
      startedAt: snapshot.started_at ?? null,
      finishedAt: snapshot.finished_at ?? null,
      log: Boolean(snapshot.log),
    };
    if (snapshot.running) {
      watched = true;
      hot = true;
    } else if (wasRunning) {
      settle();
    }
  }

  async function poll() {
    try {
      let snapshot: Forkop.InstallerSnapshot | null = null;
      if (hot && state.id) {
        const read = await options.api.read(state.id, offset);
        hot = !read.gone;
        snapshot = read.snapshot;
      }
      apply(snapshot ?? (await options.api.status(offset)));
      failingSince = null;
    } catch {
      failingSince ??= Date.now();
    }
    state.lost =
      failingSince !== null && Date.now() - failingSince >= LOST_AFTER_MS;
    emit();
    if (!shouldPoll()) {
      chain.stop();
    }
  }

  const chain = createPollChain(poll, () =>
    !shown ? BACKGROUND_POLL_MS : catchingUp ? CATCH_UP_POLL_MS : LIVE_POLL_MS,
  );

  function readNow() {
    if (chain.active) {
      chain.now();
    } else {
      chain.start(0);
    }
  }

  return {
    get state() {
      return { ...state };
    },

    // A tab coming into view reads the run once, and goes on reading while it runs.
    setShown(next: boolean) {
      shown = next;
      if (shown) {
        readNow();
      } else if (!state.running) {
        chain.stop();
      }
    },

    // Something else said a run has begun: the feed, or another page.
    refresh() {
      if (!chain.active) {
        chain.start(0);
      }
    },

    async start(
      action: Forkop.InstallerAction,
      variant = '',
      purge = false,
    ): Promise<void> {
      if (state.running || state.starting) {
        return;
      }
      state.starting = true;
      emit();
      try {
        const result = await options.api.start(
          action,
          variant,
          purge,
          options.lang(),
        );
        follow(result.id);
        state = {
          ...state,
          id: result.id,
          action: result.started ? action : null,
          starting: false,
          running: true,
          interactive: result.started
            ? action !== 'uninstall' && action !== 'check'
            : false,
          exit: null,
          interrupted: false,
          stopping: false,
          changed: false,
          checkResult: null,
          startedAt: null,
          finishedAt: null,
          log: false,
          after: null,
        };
        watched = true;
        hot = true;
        readNow();
      } catch (error) {
        state.starting = false;
        options.onStartFailed(
          error instanceof Error ? error.message : String(error),
        );
      }
      emit();
    },

    async input(data: string): Promise<void> {
      if (!state.running || !state.interactive || !state.id) {
        return;
      }
      await options.api.input(state.id, data);
      chain.now();
    },

    // install.sh stops while it has changed nothing and otherwise finishes what it changes; the
    // run's end says which.
    async stop(): Promise<void> {
      if (!state.running || !state.id || state.stopping) {
        return;
      }
      const id = state.id;
      stopAsked = true;
      state.stopping = true;
      emit();
      const accepted = await options.api.stop(id).catch(() => false);
      if (!accepted && state.id === id) {
        stopAsked = false;
      }
      readNow();
    },
  };
}
