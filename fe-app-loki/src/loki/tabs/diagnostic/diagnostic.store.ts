import {
  DIAGNOSTICS_CHECKS,
  DIAGNOSTICS_CHECKS_ORDER,
  diagnosticsCheckTitle,
} from './checks/groups';
import { IDiagnosticsChecksStoreItem, StoreType } from '../../services';

export interface DiagnosticsCheckOptions {
  includeSections?: boolean;
}

export function createDiagnosticCheck(
  code: DIAGNOSTICS_CHECKS,
  description: string,
  state: IDiagnosticsChecksStoreItem['state'] = 'skipped',
): IDiagnosticsChecksStoreItem {
  return {
    code,
    title: diagnosticsCheckTitle(code),
    order: DIAGNOSTICS_CHECKS_ORDER.indexOf(code),
    description,
    items: [],
    state,
  };
}

// List the sections check unless the configuration has no sections.
export function diagnosticsCheckCodes(options: DiagnosticsCheckOptions = {}) {
  return DIAGNOSTICS_CHECKS_ORDER.filter(
    (code) =>
      code !== DIAGNOSTICS_CHECKS.SECTIONS || options.includeSections !== false,
  );
}

export function getDiagnosticsChecks(
  description: string,
  options: DiagnosticsCheckOptions = {},
): Array<IDiagnosticsChecksStoreItem> {
  return diagnosticsCheckCodes(options).map((code) =>
    createDiagnosticCheck(code, description),
  );
}

export function getLoadingDiagnosticsChecks(
  options: DiagnosticsCheckOptions = {},
): Pick<StoreType, 'diagnosticsChecks'> {
  return {
    diagnosticsChecks: getDiagnosticsChecks(_('Pending'), options),
  };
}

export const initialDiagnosticStore: Pick<
  StoreType,
  | 'diagnosticsChecks'
  | 'diagnosticsRunAction'
  | 'diagnosticsActions'
  | 'diagnosticsSystemInfo'
> = {
  diagnosticsSystemInfo: {
    loading: true,
    loaded: false,
    capabilitiesLoaded: false,
    loki_version: 'loading',
    luci_app_version: 'loading',
    sing_box_version: 'loading',
    sing_box_variant: '',
    sections_enabled_count: -1,
    openwrt_version: 'loading',
    device_model: 'loading',
  },
  diagnosticsActions: {
    restart: {
      loading: false,
    },
    start: {
      loading: false,
    },
    stop: {
      loading: false,
    },
    enable: {
      loading: false,
    },
    disable: {
      loading: false,
    },
    report: {
      loading: false,
    },
  },
  diagnosticsRunAction: { loading: false, finished: null },
  diagnosticsChecks: getDiagnosticsChecks(_('Not running')),
};
