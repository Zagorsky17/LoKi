import type { Forkop } from '../types';
import { setCoreFeatures } from './coreFeatures.service';
import {
  getLocalActionOverlay,
  setLocalServiceAction,
} from './localActionOverlay.service';
import { store } from './store.service';
import type { StoreType } from './store.service';

type UiActionMap = Partial<Forkop.UiState['actions']>;

function isRunningAction(state: { running?: boolean }) {
  return state.running === true;
}

function getEmptyDiagnosticsActions(): StoreType['diagnosticsActions'] {
  return {
    ...store.get().diagnosticsActions,
    restart: { loading: false },
    start: { loading: false },
    stop: { loading: false },
  };
}

function applyServiceState(uiState: Forkop.UiState) {
  const currentSystemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = {
    ...currentSystemInfo,
    capabilitiesLoaded: true,
    sections_enabled_count: uiState.capabilities.sections_enabled_count,
  };

  store.set({
    serviceState: {
      loading: false,
      failed: false,
      data: {
        singbox: uiState.service.sing_box.running,
        forkopRunning: uiState.service.forkop.running,
        forkopEnabled: uiState.service.forkop.enabled,
        forkopBusy: uiState.service.forkop.busy || null,
      },
    },
    diagnosticsSystemInfo: nextSystemInfo,
  });
}

function applyActionState(actions: UiActionMap = {}) {
  // The local overlay covers only the gap between a click and the runtime reporting the job.
  for (const state of actions.service || []) {
    if (isRunningAction(state) && state.action !== 'reload') {
      setLocalServiceAction(state.action, false);
    }
  }

  const diagnosticsActions = getEmptyDiagnosticsActions();

  for (const action of getLocalActionOverlay().serviceActions) {
    diagnosticsActions[action] = { loading: true };
  }

  store.set({ diagnosticsActions });
}

export function applyUiStateToStore(uiState: Forkop.UiState) {
  setCoreFeatures(uiState.capabilities?.core);
  applyServiceState(uiState);
  applyActionState(uiState.actions);
}

// An empty store reads as a stopped, disabled service, so an unknown state is marked to keep the
// page from offering controls for it.
export function markUiStateUnavailable() {
  const serviceState = store.get().serviceState;

  store.set({
    serviceState: {
      ...serviceState,
      loading: false,
      failed: true,
    },
  });
}
