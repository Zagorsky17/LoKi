import { callUbus } from '../../helpers/callUbus';
import { isDocumentVisible } from '../../helpers/isDocumentVisible';
import { LokiShellMethods } from '../methods';
import { getLocalActionOverlay } from './localActionOverlay.service';
import { Loki } from '../types';
import { logger } from './logger.service';
import {
  LOKI_CALL_TIMEOUT_MS,
  LOKI_SERVICE_OBJECT,
  LOKI_WAIT_RETRY_MS,
  LOKI_WAIT_TIMEOUT_MS,
} from './lokiWaitTransport';
import { applyUiStateToStore, markUiStateUnavailable } from './uiState.service';
import {
  getLokiLogCursor,
  placeLokiLogFeed,
  takeLokiLogLines,
} from './lokiLogFeed.service';
import type { LogReply } from './lokiLogFeed.service';

const RUNTIME_UI_STATE_REFRESH_MIN_INTERVAL_MS = 500;
const RUNTIME_UI_STATE_IDLE_POLL_INTERVAL_MS = 10000;
const RUNTIME_UI_STATE_ACTIVE_POLL_INTERVAL_MS = 1000;
// An upgrade or a crash removes the state service for seconds, not for the life of the page.
const STATE_SERVICE_RETRY_MS = 30000;

type RuntimeUiStateListener = (uiState: Loki.UiState) => void;
type StateTransport = 'unknown' | 'ubus' | 'cli';
type UbusState = Loki.UiState & { revision?: number };

let runtimeUiStateRefreshPromise: Promise<Loki.UiState | undefined> | null =
  null;
let lastRuntimeUiStateRefreshAt = 0;
let lastRuntimeUiState: Loki.UiState | undefined;
let runtimeStateResumeRefreshRegistered = false;
let runtimeStatePollTimer: ReturnType<typeof setTimeout> | null = null;
let runtimeStatePollingStarted = false;
let runtimeStateHasRunningAction = false;
let lastRuntimeUiStateSignature = '';
let transport: StateTransport = 'unknown';
let stateServiceRetryAt = 0;
let stateRevision = 0;
let waitLoopRunning = false;
let waitLoopStop = false;
const runtimeUiStateListeners = new Set<RuntimeUiStateListener>();

function hasRunningAction(uiState: Loki.UiState) {
  return (
    Boolean(uiState.service.loki.busy) ||
    uiState.actions.service.some((action) => action.running)
  );
}

// Only the polling transport needs this: transitions come in bursts, so a changed read keeps the
// active interval for the next one.
function stateSignature(uiState: Loki.UiState) {
  const loki = uiState.service.loki;
  return [
    loki.running,
    loki.enabled,
    loki.busy || '',
    uiState.service.sing_box.running,
    uiState.actions.service.filter((action) => action.running).length,
  ].join('|');
}

// A click is known here before the runtime reports a job for it.
function hasLocalPendingAction() {
  return getLocalActionOverlay().serviceActions.size > 0;
}

function isRuntimeStateActive() {
  return runtimeStateHasRunningAction || hasLocalPendingAction();
}

function getNextPollDelay() {
  return isRuntimeStateActive()
    ? RUNTIME_UI_STATE_ACTIVE_POLL_INTERVAL_MS
    : RUNTIME_UI_STATE_IDLE_POLL_INTERVAL_MS;
}

function notifyRuntimeUiStateListeners(uiState: Loki.UiState) {
  for (const listener of runtimeUiStateListeners) {
    try {
      listener(uiState);
    } catch (error) {
      logger.error('[RUNTIME_UI_STATE]', 'listener failed', error);
    }
  }
}

function applyState(uiState: Loki.UiState) {
  applyUiStateToStore(uiState);
  lastRuntimeUiState = uiState;

  const signature = stateSignature(uiState);
  const changed = signature !== lastRuntimeUiStateSignature;
  lastRuntimeUiStateSignature = signature;

  runtimeStateHasRunningAction = hasRunningAction(uiState) || changed;
  notifyRuntimeUiStateListeners(uiState);
}

function adoptUbusState(value: UbusState) {
  if (typeof value.revision === 'number') {
    stateRevision = value.revision;
  }

  const uiState: Loki.UiState = {
    service: value.service,
    capabilities: value.capabilities,
    actions: value.actions,
  };
  applyState(uiState);
  return uiState;
}

// `state` is what the service published last, recomputed at most twice a second, so a page that
// just changed something asks for `refresh`, computed on the spot.
function useCli(reason: string) {
  transport = 'cli';
  stateServiceRetryAt = Date.now() + STATE_SERVICE_RETRY_MS;
  logger.info('[RUNTIME_UI_STATE]', 'using the CLI', reason);
}

async function readState(
  recompute: boolean,
): Promise<Loki.UiState | undefined> {
  if (transport !== 'cli' || Date.now() >= stateServiceRetryAt) {
    const response = await callUbus<UbusState>({
      object: LOKI_SERVICE_OBJECT,
      method: recompute ? 'refresh' : 'state',
      timeoutMs: LOKI_CALL_TIMEOUT_MS,
    });

    if (response.success) {
      transport = 'ubus';
      return adoptUbusState(response.data);
    }

    // A service that is present but failing is not a reason to abandon it.
    if (!response.unavailable && transport === 'ubus') {
      return undefined;
    }

    useCli(response.message);
  }

  const response = await LokiShellMethods.getUiState();
  if (!response.success) {
    // The CLI was the last transport left, so the state is reported unknown.
    markUiStateUnavailable();
    return undefined;
  }

  applyState(response.data);
  return response.data;
}

// `force` skips the poll throttle and asks the state service for a fresh computation.
export async function refreshRuntimeUiState({
  force = false,
}: { force?: boolean } = {}): Promise<Loki.UiState | undefined> {
  if (!isDocumentVisible()) {
    return undefined;
  }

  if (runtimeUiStateRefreshPromise) {
    return runtimeUiStateRefreshPromise;
  }

  const now = Date.now();
  if (
    !force &&
    now - lastRuntimeUiStateRefreshAt < RUNTIME_UI_STATE_REFRESH_MIN_INTERVAL_MS
  ) {
    return undefined;
  }

  lastRuntimeUiStateRefreshAt = now;

  const promise = readState(force)
    .catch((error) => {
      logger.error('[RUNTIME_UI_STATE]', 'refresh failed', error);
      return undefined;
    })
    .finally(() => {
      if (runtimeUiStateRefreshPromise === promise) {
        runtimeUiStateRefreshPromise = null;
      }
    });

  runtimeUiStateRefreshPromise = promise;
  return runtimeUiStateRefreshPromise;
}

function clearPollTimer() {
  if (runtimeStatePollTimer !== null && typeof window !== 'undefined') {
    window.clearTimeout(runtimeStatePollTimer);
    runtimeStatePollTimer = null;
  }
}

function scheduleRuntimeUiStatePoll(delay = getNextPollDelay()) {
  if (
    !runtimeStatePollingStarted ||
    runtimeStatePollTimer ||
    waitLoopRunning ||
    typeof window === 'undefined'
  ) {
    return;
  }

  runtimeStatePollTimer = window.setTimeout(() => {
    runtimeStatePollTimer = null;
    void refreshRuntimeUiState()
      .catch(() => undefined)
      .finally(() => {
        startTransportLoop();
      });
  }, delay);
}

// One request parked until something changes, carrying the log lines too: a browser keeps six
// connections to a host, and two parked requests per page let three pages stall LuCI.
async function runWaitLoop() {
  if (waitLoopRunning) {
    return;
  }

  waitLoopRunning = true;
  waitLoopStop = false;

  try {
    while (!waitLoopStop && isDocumentVisible() && transport === 'ubus') {
      await placeLokiLogFeed();
      const cursor = getLokiLogCursor();
      const response = await callUbus<UbusState & LogReply>({
        object: LOKI_SERVICE_OBJECT,
        method: 'state_wait',
        params:
          cursor === undefined
            ? { revision: stateRevision }
            : { revision: stateRevision, cursor },
        timeoutMs: LOKI_WAIT_TIMEOUT_MS,
        nobatch: true,
      });

      if (waitLoopStop) {
        break;
      }

      if (response.success) {
        adoptUbusState(response.data);
        takeLokiLogLines(response.data);
        continue;
      }

      if (response.unavailable) {
        useCli(response.message);
        break;
      }

      logger.error('[RUNTIME_UI_STATE]', 'state wait failed', response.message);
      await new Promise((resolve) => setTimeout(resolve, LOKI_WAIT_RETRY_MS));
    }
  } finally {
    waitLoopRunning = false;
    if (runtimeStatePollingStarted && transport !== 'ubus') {
      scheduleRuntimeUiStatePoll();
    }
  }
}

function startTransportLoop() {
  if (!runtimeStatePollingStarted) {
    return;
  }

  if (transport === 'ubus') {
    clearPollTimer();
    // A loop hidden a moment ago may still be waiting on its request and carries on.
    waitLoopStop = false;
    void runWaitLoop();
    return;
  }

  scheduleRuntimeUiStatePoll();
}

// The page started or finished an action of its own, so the state is read again at once.
export function refreshRuntimeUiStateNow() {
  clearPollTimer();

  const refreshed = refreshRuntimeUiState({ force: true });
  if (runtimeStatePollingStarted) {
    void refreshed.finally(() => {
      startTransportLoop();
    });
  }
  return refreshed;
}

export function subscribeRuntimeUiState(listener: RuntimeUiStateListener) {
  runtimeUiStateListeners.add(listener);

  if (lastRuntimeUiState) {
    try {
      listener(lastRuntimeUiState);
    } catch (error) {
      logger.error('[RUNTIME_UI_STATE]', 'listener failed', error);
    }
  }

  return () => {
    runtimeUiStateListeners.delete(listener);
  };
}

// Which transport answered is remembered for the life of the page; tests need
// to be able to forget it between cases.
export function resetRuntimeUiStateTransport() {
  transport = 'unknown';
  stateServiceRetryAt = 0;
  stateRevision = 0;
  lastRuntimeUiState = undefined;
  lastRuntimeUiStateSignature = '';
  lastRuntimeUiStateRefreshAt = 0;
}

export function getCachedRuntimeUiState() {
  return lastRuntimeUiState;
}

export function registerRuntimeStateResumeRefresh() {
  if (runtimeStateResumeRefreshRegistered || typeof window === 'undefined') {
    return;
  }

  runtimeStateResumeRefreshRegistered = true;

  const onVisibilityChange = () => {
    if (!isDocumentVisible()) {
      // A request parked from a hidden tab holds a connection open for nothing.
      waitLoopStop = true;
      clearPollTimer();
      return;
    }

    void refreshRuntimeUiStateNow();
  };

  document.addEventListener('visibilitychange', onVisibilityChange);
  window.addEventListener('pageshow', onVisibilityChange);
  window.addEventListener('focus', onVisibilityChange);
}

export function startRuntimeUiStatePolling() {
  if (runtimeStatePollingStarted || typeof window === 'undefined') {
    return;
  }

  runtimeStatePollingStarted = true;
  void refreshRuntimeUiState({ force: true }).finally(() => {
    startTransportLoop();
  });
}
