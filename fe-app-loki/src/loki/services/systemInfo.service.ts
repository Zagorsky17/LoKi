import { LokiShellMethods } from '../methods';
import { logger } from './logger.service';
import { store, StoreType } from './store.service';

const UNKNOWN_SYSTEM_INFO: StoreType['diagnosticsSystemInfo'] = {
  loading: false,
  loaded: false,
  capabilitiesLoaded: false,
  loki_version: _('unknown'),
  luci_app_version: _('unknown'),
  sing_box_version: _('unknown'),
  sing_box_variant: '',
  sections_enabled_count: -1,
  openwrt_version: _('unknown'),
  device_model: _('unknown'),
};

let systemInfoPromise: Promise<StoreType['diagnosticsSystemInfo']> | null =
  null;
let latestSystemInfoRequestId = 0;

function hasLoadedSystemInfo() {
  const systemInfo = store.get().diagnosticsSystemInfo;

  return Boolean(systemInfo.loaded) && !systemInfo.loading;
}

export async function ensureSystemInfo({
  force = false,
  silent = false,
}: {
  force?: boolean;
  silent?: boolean;
} = {}) {
  if (!force && hasLoadedSystemInfo()) {
    return store.get().diagnosticsSystemInfo;
  }

  if (systemInfoPromise && !force) {
    return systemInfoPromise;
  }

  const requestId = ++latestSystemInfoRequestId;
  const currentSystemInfo = store.get().diagnosticsSystemInfo;

  if (!silent) {
    store.set({
      diagnosticsSystemInfo: {
        ...currentSystemInfo,
        loading: true,
      },
    });
  }

  const promise = (async () => {
    try {
      const systemInfo = await LokiShellMethods.getSystemInfo();

      if (requestId !== latestSystemInfoRequestId) {
        return store.get().diagnosticsSystemInfo;
      }

      if (systemInfo.success) {
        const nextSystemInfo: StoreType['diagnosticsSystemInfo'] = {
          ...UNKNOWN_SYSTEM_INFO,
          loading: false,
          loaded: true,
          capabilitiesLoaded: true,
          sections_enabled_count: currentSystemInfo.sections_enabled_count,
          ...systemInfo.data,
        };

        store.set({
          diagnosticsSystemInfo: nextSystemInfo,
        });

        return nextSystemInfo;
      }
    } catch (error) {
      logger.error('[SYSTEM_INFO]', 'ensureSystemInfo failed', error);
    }

    if (requestId === latestSystemInfoRequestId && !silent) {
      const latestSystemInfo = store.get().diagnosticsSystemInfo;
      const nextSystemInfo = {
        ...UNKNOWN_SYSTEM_INFO,
        loading: false,
        loaded: false,
        capabilitiesLoaded: latestSystemInfo.capabilitiesLoaded,
        sections_enabled_count: latestSystemInfo.sections_enabled_count,
      };

      store.set({
        diagnosticsSystemInfo: nextSystemInfo,
      });

      return nextSystemInfo;
    }

    return store.get().diagnosticsSystemInfo;
  })();

  systemInfoPromise = promise;

  try {
    return await promise;
  } finally {
    if (systemInfoPromise === promise) {
      systemInfoPromise = null;
    }
  }
}
