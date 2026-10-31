// Modified for LoKi on 2026-11-01: carry the requested privacy mode into report formatting.
import { onMount } from '../../../helpers/onMount';
import { preserveScrollForPage } from '../../../helpers/preserveScrollForPage';
import { runServiceCheck } from './checks/service';
import { runDnsCheck } from './checks/dns';
import { runTrafficCheck } from './checks/traffic';
import { runSectionsCheck } from './checks/sections';
import { runServersCheck } from './checks/servers';
import { CheckOutcome, skipped, unanswered } from './checks/present';
import { DIAGNOSTICS_CHECKS } from './checks/groups';
import {
  createDiagnosticCheck,
  DiagnosticsCheckOptions,
  diagnosticsCheckCodes,
  getDiagnosticsChecks,
  getLoadingDiagnosticsChecks,
} from './diagnostic.store';
import { checksText, reportText } from './report';
import {
  logger,
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  refreshRuntimeUiStateNow,
  setLocalServiceAction,
  store,
  StoreType,
  subscribeRuntimeUiState,
} from '../../services';
import { showToast } from '../../../helpers/showToast';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import {
  renderAvailableActions,
  renderCheckSection,
  renderRunAction,
  renderSystemInfo,
} from './partials';
import { ForkopShellMethods } from '../../methods';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { renderModal } from '../../../partials';
import { FORKOP_LUCI_APP_VERSION } from '../../../constants';
import { Forkop } from '../../types';
import {
  getAutostartControlsPresentation,
  getServiceControlsPresentation,
  getServiceOperation,
  serviceActionFailureMessage,
  shouldDisableDiagnosticRunAction,
} from './serviceTransition';
import type { ServiceOperation } from './serviceTransition';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { formatOsRelease } from '../../helpers/osRelease';
import { formatSingBoxVersion } from '../../helpers/singBoxVersion';

let latestCapabilitiesRequestId = 0;
let diagnosticLifecycleRegistered = false;
let diagnosticControllerInitialized = false;
let diagnosticMounted = false;
let diagnosticMountId = 0;
// Idle, the check list is a placeholder rebuilt by every capability read; from the start of a run
// it belongs to the run until the page is left or a service action makes the result stale. A tab
// switch starts several capability reads, and none may overwrite the run's list.
let diagnosticsChecksOwnedByRun = false;
const handledServiceActionJobs = new Set<string>();
// Folding chosen by hand, per check, until the next run lays the list out again.
const checkFolding = new Map<string, boolean>();
// What the service check of the run in flight found.
let forkopRunningInRun = true;
let runServiceData: Forkop.ServiceCheckResult | undefined;

const UNKNOWN_COUNTS = {
  server_inbounds_enabled_count: -1,
  sections_enabled_count: -1,
};

type ServiceRuntimeAction = 'restart' | 'start' | 'stop';
type DiagnosticRunner = {
  code: DIAGNOSTICS_CHECKS;
  run: () => Promise<CheckOutcome>;
};

// Idle, an unknown count lists the sections, which most configurations have, and not the servers.
function getDiagnosticsCheckOptions(
  systemInfo: Pick<
    StoreType['diagnosticsSystemInfo'],
    'server_inbounds_enabled_count' | 'sections_enabled_count'
  > = store.get().diagnosticsSystemInfo,
): DiagnosticsCheckOptions {
  return {
    includeServers: systemInfo.server_inbounds_enabled_count > 0,
    includeSections: systemInfo.sections_enabled_count !== 0,
  };
}

function getNotRunningDiagnosticsChecks(
  systemInfo = store.get().diagnosticsSystemInfo,
) {
  return getDiagnosticsChecks(
    _('Not running'),
    getDiagnosticsCheckOptions(systemInfo),
  );
}

function rebuildIdleDiagnosticsChecks(
  systemInfo = store.get().diagnosticsSystemInfo,
) {
  if (diagnosticsChecksOwnedByRun) {
    return;
  }

  store.set({
    diagnosticsChecks: getNotRunningDiagnosticsChecks(systemInfo),
  });
}

// A run still filling the list keeps it.
function releaseDiagnosticsChecks() {
  if (store.get().diagnosticsRunAction.loading) {
    return;
  }

  diagnosticsChecksOwnedByRun = false;
  store.set({ diagnosticsRunAction: { loading: false, finished: null } });
  rebuildIdleDiagnosticsChecks();
}

// A click shows at once through the local overlay; everything after comes from the runtime feed,
// with nothing polled here.
function setDiagnosticActionLoading(
  action: keyof StoreType['diagnosticsActions'],
  loading: boolean,
) {
  setLocalServiceAction(action, loading);

  const diagnosticsActions = store.get().diagnosticsActions;

  store.set({
    diagnosticsActions: {
      ...diagnosticsActions,
      [action]: { loading },
    },
  });
}

function isDiagnosticMountActive(mountId = diagnosticMountId) {
  return diagnosticMounted && diagnosticMountId === mountId;
}

function getLocalPendingServiceOperation(
  actions: StoreType['diagnosticsActions'],
): ServiceOperation | null {
  if (actions.restart.loading) {
    return 'restart';
  }
  if (actions.start.loading) {
    return 'start';
  }
  if (actions.stop.loading) {
    return 'stop';
  }
  return null;
}

// A finished action is acknowledged once per job, whichever page started it. Failures are not
// reported here: each is logged as an error, which already raises an alert.
function settleFinishedServiceActions(uiState: Forkop.UiState) {
  for (const action of uiState.actions.service || []) {
    if (!action.job_id || action.running) {
      continue;
    }

    if (handledServiceActionJobs.has(action.job_id)) {
      continue;
    }

    handledServiceActionJobs.add(action.job_id);
    void ForkopShellMethods.uiActionAck(action.job_id);
    releaseDiagnosticsChecks();
  }
}

async function fetchSystemInfo() {
  rebuildIdleDiagnosticsChecks(await ensureSystemInfo());
}

function applyDiagnosticsCapabilities(
  nextSystemInfo: StoreType['diagnosticsSystemInfo'],
  resetChecks: boolean,
) {
  const nextState: Partial<StoreType> = {
    diagnosticsSystemInfo: nextSystemInfo,
  };

  if (resetChecks && !diagnosticsChecksOwnedByRun) {
    nextState.diagnosticsChecks =
      getNotRunningDiagnosticsChecks(nextSystemInfo);
  }

  store.set(nextState);
}

async function fetchDiagnosticsCapabilities({
  resetChecks = true,
}: { resetChecks?: boolean } = {}) {
  const requestId = ++latestCapabilitiesRequestId;

  try {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (requestId !== latestCapabilitiesRequestId) {
      return;
    }

    if (uiState) {
      const currentSystemInfo = store.get().diagnosticsSystemInfo;
      const nextSystemInfo = {
        ...currentSystemInfo,
        capabilitiesLoaded: true,
        server_inbounds_enabled_count:
          uiState.capabilities.server_inbounds_enabled_count,
        sections_enabled_count: uiState.capabilities.sections_enabled_count,
      };

      applyDiagnosticsCapabilities(nextSystemInfo, resetChecks);
      return;
    }

    // Without the runtime feed the counts are unknown, and the checks decide themselves.
    const nextSystemInfo = {
      ...store.get().diagnosticsSystemInfo,
      capabilitiesLoaded: true,
      ...UNKNOWN_COUNTS,
    };

    applyDiagnosticsCapabilities(nextSystemInfo, resetChecks);
  } catch (error) {
    logger.error('[DIAGNOSTIC]', 'fetchDiagnosticsCapabilities failed', error);

    if (requestId === latestCapabilitiesRequestId) {
      const currentSystemInfo = store.get().diagnosticsSystemInfo;

      store.set({
        diagnosticsSystemInfo: {
          ...currentSystemInfo,
          capabilitiesLoaded: true,
          ...UNKNOWN_COUNTS,
        },
      });
    }
  }
}

function renderDiagnosticsChecks() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticsChecks');
  const diagnosticsChecks = [...store.get().diagnosticsChecks].sort(
    (a, b) => a.order - b.order,
  );
  const container = document.getElementById('fkp_diagnostic-page-checks');

  const renderedDiagnosticsChecks = diagnosticsChecks.map((check) => {
    const expanded =
      checkFolding.get(check.code) ??
      (check.state === 'warning' || check.state === 'error');
    return renderCheckSection(check, {
      expanded,
      onToggle: () => {
        checkFolding.set(check.code, !expanded);
        renderDiagnosticsChecks();
      },
    });
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(...renderedDiagnosticsChecks);
  });
}

function renderDiagnosticRunActionWidget() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticRunActionWidget');

  const { loading, finished } = store.get().diagnosticsRunAction;
  const { diagnosticsActions, serviceState } = store.get();
  const capabilitiesLoaded =
    store.get().diagnosticsSystemInfo.capabilitiesLoaded;
  const container = document.getElementById('fkp_diagnostic-page-run-check');
  const disabled = shouldDisableDiagnosticRunAction({
    capabilitiesLoaded,
    operation: getServiceOperation({
      busy: serviceState.data.forkopBusy,
      localPending: getLocalPendingServiceOperation(diagnosticsActions),
    }),
  });

  const renderedAction = renderRunAction({
    loading,
    disabled,
    click: () => runChecks(),
    // The report is the result of a run, so it is offered once one finished.
    report:
      finished && !loading
        ? {
            loading: diagnosticsActions.report.loading,
            disabled: diagnosticsActions.report.loading,
            click: () => handleReport(),
          }
        : null,
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedAction);
  });
}

// Completion is settled by the feed listener; only a start that never became a job is cleaned
// up here.
async function handleServiceRuntimeAction(action: ServiceRuntimeAction) {
  setDiagnosticActionLoading(action, true);

  try {
    const startResponse = await ForkopShellMethods.serviceActionStart(action);

    if (!startResponse.success) {
      throw new Error(startResponse.error);
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', `handleServiceRuntimeAction(${action})`, e);
    showToast(serviceActionFailureMessage(action), 'error');
    setDiagnosticActionLoading(action, false);
  } finally {
    void refreshRuntimeUiStateNow();
  }
}

async function handleRestart() {
  await handleServiceRuntimeAction('restart');
}

async function handleStart() {
  await handleServiceRuntimeAction('start');
}

async function handleStop() {
  await handleServiceRuntimeAction('stop');
}

// Autostart has no job: the shown button follows service.forkop.enabled, so the pressed one spins
// until the new value arrives, and a switch that did not move is reported.
async function handleAutostartAction(
  action: 'enable' | 'disable',
  request: () => Promise<{ success: boolean }>,
  failure: string,
) {
  setDiagnosticActionLoading(action, true);

  const result = await request().catch(() => ({ success: false }));
  if (!result.success) {
    showToast(failure, 'error');
  }

  await refreshRuntimeUiStateNow();
  setDiagnosticActionLoading(action, false);
}

async function handleEnable() {
  await handleAutostartAction(
    'enable',
    () => ForkopShellMethods.enable(),
    _('Could not enable autostart'),
  );
}

async function handleDisable() {
  await handleAutostartAction(
    'disable',
    () => ForkopShellMethods.disable(),
    _('Could not disable autostart'),
  );
}

// The finished run's checks plus what the router adds; masked, the router hides the same values
// in the checks.
async function buildReport(masked: boolean) {
  const run = store.get().diagnosticsRunAction.finished;
  const attachments = await ForkopShellMethods.report(
    masked,
    checksText(store.get().diagnosticsChecks),
  );
  if (!attachments.success) {
    throw new Error(attachments.error || 'Failed to collect the report');
  }
  return reportText(
    {
      visibility: masked ? 'masked' : 'raw',
      generatedAt: new Date(),
      systemInfo: store.get().diagnosticsSystemInfo,
      luciVersion: normalizeCompiledVersion(FORKOP_LUCI_APP_VERSION),
      service: run?.service,
    },
    attachments.data,
  );
}

async function handleReport() {
  setDiagnosticActionLoading('report', true);

  try {
    const getText = ({ maskValues }: { maskValues: boolean }) =>
      buildReport(maskValues);
    const text = await getText({ maskValues: true });

    ui.showModal(
      _('Diagnostic report'),
      renderModal(text, 'forkop-report', {
        getText,
        showMaskValuesToggle: true,
      }),
    );
  } catch (error) {
    logger.error('[DIAGNOSTIC]', 'report', error);
    showToast(_('Failed to load diagnostics'), 'error');
  } finally {
    setDiagnosticActionLoading('report', false);
  }
}

function renderDiagnosticAvailableActionsWidget() {
  const diagnosticsActions = store.get().diagnosticsActions;
  const serviceState = store.get().serviceState;
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticAvailableActionsWidget');

  const forkopEnabled = Boolean(serviceState.data.forkopEnabled);
  const forkopRunning = Boolean(serviceState.data.forkopRunning);
  const operation = getServiceOperation({
    busy: serviceState.data.forkopBusy,
    localPending: getLocalPendingServiceOperation(diagnosticsActions),
  });
  // Nothing is said about the service until the first snapshot arrives.
  const stateKnown = !serviceState.loading || serviceState.failed;
  const controls = getServiceControlsPresentation({
    running: forkopRunning,
    operation,
    known: stateKnown,
  });
  const autostart = getAutostartControlsPresentation({
    enabled: forkopEnabled,
    enableLoading: diagnosticsActions.enable.loading,
    disableLoading: diagnosticsActions.disable.loading,
    known: stateKnown,
  });

  const container = document.getElementById('fkp_diagnostic-page-actions');

  const renderedActions = renderAvailableActions({
    restart: { ...controls.restart, onClick: handleRestart },
    start: { ...controls.start, onClick: handleStart },
    stop: { ...controls.stop, onClick: handleStop },
    enable: { ...autostart.enable, onClick: handleEnable },
    disable: { ...autostart.disable, onClick: handleDisable },
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedActions);
  });
}

function renderDiagnosticSystemInfoWidget() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticSystemInfoWidget');
  const diagnosticsSystemInfo = store.get().diagnosticsSystemInfo;

  const container = document.getElementById('fkp_diagnostic-page-system-info');

  const forkopVersion = normalizeCompiledVersion(
    diagnosticsSystemInfo.forkop_version,
  );
  const luciVersion = normalizeCompiledVersion(FORKOP_LUCI_APP_VERSION);
  // The page's own version shows only when it differs from the backend's.
  const items = [
    { key: 'Forkop', value: forkopVersion },
    ...(diagnosticsSystemInfo.loaded && luciVersion !== forkopVersion
      ? [{ key: 'LuCI', value: luciVersion }]
      : []),
    {
      key: 'sing-box-forkop',
      value: formatSingBoxVersion(diagnosticsSystemInfo),
      badge: diagnosticsSystemInfo.sing_box_variant,
    },
    {
      key: _('OS'),
      value: formatOsRelease(diagnosticsSystemInfo.openwrt_version),
    },
    { key: _('Device'), value: diagnosticsSystemInfo.device_model },
  ];

  const renderedSystemInfo = renderSystemInfo({
    items,
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedSystemInfo);
  });
}

async function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.diagnosticsChecks) {
    renderDiagnosticsChecks();
  }

  if (
    diff.diagnosticsRunAction ||
    diff.diagnosticsSystemInfo ||
    diff.diagnosticsActions ||
    diff.serviceState
  ) {
    renderDiagnosticRunActionWidget();
  }

  if (diff.diagnosticsActions || diff.serviceState) {
    renderDiagnosticAvailableActionsWidget();
  }

  if (diff.diagnosticsSystemInfo) {
    renderDiagnosticSystemInfoWidget();
  }
}

function setDiagnosticCheck(code: DIAGNOSTICS_CHECKS, result: CheckOutcome) {
  const other = store
    .get()
    .diagnosticsChecks.filter((item) => item.code !== code);

  store.set({
    diagnosticsChecks: [
      ...other,
      { ...createDiagnosticCheck(code, result.description), ...result },
    ],
  });
}

// With Forkop down the runtime checks would only repeat that it is down.
function getDiagnosticRunners(
  checkOptions: DiagnosticsCheckOptions,
): DiagnosticRunner[] {
  const runners: Record<DIAGNOSTICS_CHECKS, () => Promise<CheckOutcome>> = {
    [DIAGNOSTICS_CHECKS.SERVICE]: async () => {
      const service = await runServiceCheck();
      runServiceData = service.data;
      forkopRunningInRun = service.running;
      return service.result;
    },
    [DIAGNOSTICS_CHECKS.DNS]: runDnsCheck,
    [DIAGNOSTICS_CHECKS.TRAFFIC]: runTrafficCheck,
    [DIAGNOSTICS_CHECKS.SECTIONS]: runSectionsCheck,
    [DIAGNOSTICS_CHECKS.SERVERS]: runServersCheck,
  };

  return diagnosticsCheckCodes(checkOptions).map((code) => ({
    code,
    run: () =>
      code === DIAGNOSTICS_CHECKS.SERVICE || forkopRunningInRun
        ? runners[code]()
        : Promise.resolve(skipped(_('Skipped: Forkop is not running'))),
  }));
}

// One pass per page session. The run outlives the tab: a LuCI tab switch unmounts the page while
// the loop keeps writing into the shared store, so coming back re-renders its progress.
async function runChecks() {
  if (store.get().diagnosticsRunAction.loading) {
    return;
  }

  let finished: StoreType['diagnosticsRunAction']['finished'] = null;
  diagnosticsChecksOwnedByRun = true;
  checkFolding.clear();
  store.set({
    diagnosticsRunAction: { loading: true, finished: null },
    diagnosticsChecks: getLoadingDiagnosticsChecks(getDiagnosticsCheckOptions())
      .diagnosticsChecks,
  });

  try {
    await fetchDiagnosticsCapabilities({ resetChecks: false });

    // A run checks the servers and sections unless it knows there are none.
    const { server_inbounds_enabled_count, sections_enabled_count } =
      store.get().diagnosticsSystemInfo;
    const checkOptions = {
      includeServers: server_inbounds_enabled_count !== 0,
      includeSections: sections_enabled_count !== 0,
    };

    store.set({
      diagnosticsChecks:
        getLoadingDiagnosticsChecks(checkOptions).diagnosticsChecks,
    });

    forkopRunningInRun = true;
    runServiceData = undefined;

    for (const runner of getDiagnosticRunners(checkOptions)) {
      setDiagnosticCheck(runner.code, {
        state: 'loading',
        description: _('Checking, please wait'),
        items: [],
      });

      try {
        setDiagnosticCheck(runner.code, await runner.run());
      } catch (e) {
        logger.error('[DIAGNOSTIC]', `runChecks - ${runner.code} failed`, e);
        setDiagnosticCheck(runner.code, unanswered());
      }
    }

    finished = { service: runServiceData };
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'runChecks - e', e);
  } finally {
    store.set({ diagnosticsRunAction: { loading: false, finished } });
  }
}

async function loadInitialDiagnosticData() {
  const diagnosticStatus = document.getElementById('diagnostic-status');

  if (diagnosticStatus?.isConnected && diagnosticStatus.offsetParent !== null) {
    if (store.get().diagnosticsRunAction.loading) {
      return;
    }

    await fetchSystemInfo();
    await fetchDiagnosticsCapabilities();
  }
}

// The current mount owns the listeners; the check list belongs to the page and its run.
function detachDiagnosticPage() {
  diagnosticMounted = false;
  diagnosticMountId += 1;

  store.unsubscribe(onStoreUpdate);
}

async function onPageMount() {
  detachDiagnosticPage();

  diagnosticMounted = true;
  diagnosticMountId += 1;
  const mountId = diagnosticMountId;
  const hasRuntimeSnapshot = Boolean(getCachedRuntimeUiState());

  if (!hasRuntimeSnapshot) {
    await refreshRuntimeUiState({ force: true });

    if (!isDiagnosticMountActive(mountId)) {
      return;
    }
  }

  store.subscribe(onStoreUpdate);

  renderDiagnosticsChecks();

  renderDiagnosticRunActionWidget();

  renderDiagnosticAvailableActionsWidget();

  renderDiagnosticSystemInfoWidget();

  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }

  void loadInitialDiagnosticData();
}

function onPageUnmount() {
  detachDiagnosticPage();
  releaseDiagnosticsChecks();
}

function registerLifecycleListeners() {
  if (diagnosticLifecycleRegistered) {
    return;
  }

  diagnosticLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      logger.debug(
        '[DIAGNOSTIC]',
        'active tab diff event, active tab:',
        diff.tabService.current,
      );
      const isDIAGNOSTICVisible = next.tabService.current === 'diagnostic';

      if (isDIAGNOSTICVisible) {
        logger.debug(
          '[DIAGNOSTIC]',
          'registerLifecycleListeners',
          'onPageMount',
        );
        return onPageMount();
      }

      if (!isDIAGNOSTICVisible) {
        logger.debug(
          '[DIAGNOSTIC]',
          'registerLifecycleListeners',
          'onPageUnmount',
        );
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (diagnosticControllerInitialized) {
    return;
  }

  diagnosticControllerInitialized = true;

  // For the life of the page: an action keeps running when the user leaves the tab.
  subscribeRuntimeUiState(settleFinishedServiceActions);

  onMount('diagnostic-status').then(() => {
    logger.debug('[DIAGNOSTIC]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'diagnostic' ||
      isActiveLuciTab('diagnostic')
    ) {
      onPageMount();
    }
  });
}
