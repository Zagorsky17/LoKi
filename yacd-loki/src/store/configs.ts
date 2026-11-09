import {
  DispatchFn,
  GetStateFn,
  State,
  StateConfigs,
} from '~/store/types';
import { ClashAPIConfig } from '~/types';

import * as configsAPI from '../api/configs';

export const getConfigs = (s: State) => s.configs.configs;
export const getHaveFetched = (s: State) => s.configs.haveFetchedConfig;
export const getLogLevel = (s: State) => s.configs.configs['log-level'];

const STARTUP_TIMEOUT_MS = 2000;

export function fetchConfigs(apiConfig: ClashAPIConfig) {
  return async (dispatch: DispatchFn, getState: GetStateFn) => {
    let res: Response;
    const haveFetched = getHaveFetched(getState());
    const controller = new AbortController();
    const timeoutId = haveFetched ? null : setTimeout(() => controller.abort(), STARTUP_TIMEOUT_MS);
    try {
      res = await configsAPI.fetchConfigs(apiConfig, haveFetched ? undefined : controller.signal);
    } catch (err) {
      // TypeError and AbortError (includes timeout)
      console.warn('LoKi gateway is unavailable');
      return;
    } finally {
      if (timeoutId !== null) clearTimeout(timeoutId);
    }

    if (!res.ok) {
      console.log('Error fetch configs', res.statusText);
      console.warn('LoKi gateway refused the configuration request');
      return;
    }

    const payload = await res.json();

    dispatch('store/configs#fetchConfigs', (s) => {
      s.configs.configs = payload;
    });

    const haveFetchedConfig = getHaveFetched(getState());
    if (!haveFetchedConfig) {
      dispatch(markHaveFetchedConfig());
    }
  };
}

function markHaveFetchedConfig() {
  return (dispatch: DispatchFn) => {
    dispatch('store/configs#markHaveFetchedConfig', (s: State) => {
      s.configs.haveFetchedConfig = true;
    });
  };
}

export const initialState: StateConfigs = {
  configs: {
    port: 7890,
    'socks-port': 7891,
    'mixed-port': 0,
    'redir-port': 0,
    'tproxy-port': 0,
    'mitm-port': 0,
    'allow-lan': false,
    mode: 'rule',
    'log-level': 'uninit',
    sniffing: false,
    tun: {
      enable: false,
      device: '',
      stack: '',
      'dns-hijack': [],
      'auto-route': false,
    },
  },
  haveFetchedConfig: false,
};
