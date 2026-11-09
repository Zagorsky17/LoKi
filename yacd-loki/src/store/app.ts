import { DispatchFn, GetStateFn, State, StateApp } from '~/store/types';

import { DEFAULT_LATENCY_TEST_URL, PROVIDER_HEALTHCHECK_TIMEOUT } from '../misc/constants';
import { loadState, saveState } from '../misc/storage';
import { debounce } from '../misc/utils';

export const getClashAPIConfig = (s: State) => {
  const idx = s.app.selectedClashAPIConfigIndex;
  return s.app.clashAPIConfigs[idx];
};
export const getTheme = (s: State) => s.app.theme;
export const getSelectedChartStyleIndex = (s: State) => s.app.selectedChartStyleIndex;
export const getLatencyTestUrl = (s: State) => s.app.latencyTestUrl;
export const getLatencyTestTimeout = (s: State) => s.app.latencyTestTimeout;
export const getPreferBackendLatencyTestUrl = (s: State) => s.app.preferBackendLatencyTestUrl;
export const getProviderHealthcheckTimeout = (s: State) => s.app.providerHealthcheckTimeout;
export const getCollapsibleIsOpen = (s: State) => s.app.collapsibleIsOpen;
export const getProxySortBy = (s: State) => s.app.proxySortBy;
export const getHideUnavailableProxies = (s: State) => s.app.hideUnavailableProxies;
export const getAutoCloseOldConns = (s: State) => s.app.autoCloseOldConns;
export const getLogStreamingPaused = (s: State) => s.app.logStreamingPaused;
export const getProxiesLayout = (s: State) => s.app.proxiesLayout;
export const getProxyGroupByProvider = (s: State) => s.app.proxyGroupByProvider;

const saveStateDebounced = debounce(saveState, 600);

const rootEl = document.documentElement;
type ThemeType = 'dark' | 'light' | 'auto';

function setTheme(theme: ThemeType = 'light') {
  if (theme === 'auto') {
    rootEl.setAttribute('data-theme', 'auto');
  } else if (theme === 'dark') {
    rootEl.setAttribute('data-theme', 'dark');
  } else {
    rootEl.setAttribute('data-theme', 'light');
  }
}

export function switchTheme(nextTheme = 'auto') {
  return (dispatch: DispatchFn, getState: GetStateFn) => {
    const currentTheme = getTheme(getState());
    if (currentTheme === nextTheme) return;
    // side effect
    setTheme(nextTheme as ThemeType);
    dispatch('storeSwitchTheme', (s) => {
      s.app.theme = nextTheme;
    });
    // side effect
    saveState(getState().app);
  };
}

export function selectChartStyleIndex(selectedChartStyleIndex: number | string) {
  return (dispatch: DispatchFn, getState: GetStateFn) => {
    dispatch('appSelectChartStyleIndex', (s) => {
      s.app.selectedChartStyleIndex = Number(selectedChartStyleIndex);
    });
    // side effect
    saveState(getState().app);
  };
}

export function updateAppConfig<K extends keyof StateApp>(name: K, value: StateApp[K]) {
  return (dispatch: DispatchFn, getState: GetStateFn) => {
    dispatch('appUpdateAppConfig', (s) => {
      s.app[name] = value;
    });
    // side effect
    saveState(getState().app);
  };
}

export function updateCollapsibleIsOpen(prefix: string, name: string, v: boolean) {
  return (dispatch: DispatchFn, getState: GetStateFn) => {
    dispatch('updateCollapsibleIsOpen', (s: State) => {
      s.app.collapsibleIsOpen[`${prefix}:${name}`] = v;
    });
    // side effect
    saveStateDebounced(getState().app);
  };
}

/** 一次性展开/收起同一前缀下的多个分组（代理页的「全部收起 / 全部展开」） */
export function updateCollapsibleIsOpenBulk(prefix: string, names: string[], v: boolean) {
  return (dispatch: DispatchFn, getState: GetStateFn) => {
    dispatch('updateCollapsibleIsOpenBulk', (s: State) => {
      for (const name of names) {
        s.app.collapsibleIsOpen[`${prefix}:${name}`] = v;
      }
    });
    // side effect
    saveStateDebounced(getState().app);
  };
}

const defaultClashAPIConfig = {
  baseURL: window.location.origin + '/cgi-bin/luci/loki-gateway/api',
  secret: '',
  addedAt: 0,
};
// type Theme = 'light' | 'dark';
const defaultState: StateApp = {
  selectedClashAPIConfigIndex: 0,
  clashAPIConfigs: [defaultClashAPIConfig],

  latencyTestUrl: DEFAULT_LATENCY_TEST_URL,
  latencyTestTimeout: 5000,
  preferBackendLatencyTestUrl: true,
  providerHealthcheckTimeout: PROVIDER_HEALTHCHECK_TIMEOUT,
  selectedChartStyleIndex: 0,
  theme: 'auto',

  // type { [string]: boolean }
  collapsibleIsOpen: {},
  // how proxies are sorted in a group or provider
  proxySortBy: 'Natural',
  hideUnavailableProxies: false,
  autoCloseOldConns: true,
  logStreamingPaused: false,
  proxiesLayout: 'double',
  proxyGroupByProvider: false,
};

export function initialState() {
  const persisted = loadState();
  const s: StateApp = {
    ...defaultState,
    ...persisted,
    selectedClashAPIConfigIndex: 0,
    clashAPIConfigs: [defaultClashAPIConfig],
  };
  // Re-save without any old backend address or bearer secret.
  saveState(s);
  setTheme(s.theme as ThemeType);
  return s;
}
