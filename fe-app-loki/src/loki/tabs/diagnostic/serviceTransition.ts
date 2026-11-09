import type { Loki } from '../../types';

// What the service is doing now: service.loki.busy, or a freshly clicked button until the
// runtime reports its job.
export type ServiceOperation = Loki.ServiceBusy;

type ServiceControlMode = 'restart' | 'apply';

type LoadingActionState = {
  loading: boolean;
};

type DiagnosticServiceActions = {
  restart: LoadingActionState;
  start: LoadingActionState;
  stop: LoadingActionState;
  enable: LoadingActionState;
  disable: LoadingActionState;
};

interface ServiceControlState {
  visible: boolean;
  loading: boolean;
  disabled: boolean;
}

interface ServiceControlsPresentation {
  restart: ServiceControlState & { mode: ServiceControlMode };
  start: ServiceControlState;
  stop: ServiceControlState;
}

export function getServiceOperation({
  busy,
  localPending,
}: {
  busy?: Loki.ServiceBusy | null;
  localPending?: ServiceOperation | null;
}): ServiceOperation | null {
  return busy || localPending || null;
}

export function isServiceBusy(operation: ServiceOperation | null) {
  return operation !== null;
}

// While an operation runs its own button is the only control shown, spinning and disabled;
// Restart is offered when there is something to restart, Start when the service is down and
// idle. This is presentation, not protection: the runtime lock serializes actions and refuses
// any action while another runs.
export function getServiceControlsPresentation({
  running,
  operation,
  known = true,
}: {
  running: boolean;
  operation: ServiceOperation | null;
  known?: boolean;
}): ServiceControlsPresentation {
  // An empty store reads like a stopped service, so nothing is offered before the state arrives,
  // as after LuCI reloads the view on Save & Apply.
  if (!known) {
    const hidden = { visible: false, loading: false, disabled: true };
    return {
      restart: { ...hidden, mode: 'restart' },
      start: { ...hidden },
      stop: { ...hidden },
    };
  }

  const applying = operation === 'apply';
  const restarting = operation === 'restart' || applying;
  const idle = operation === null;

  return {
    restart: {
      mode: applying ? 'apply' : 'restart',
      visible: restarting || (running && idle),
      loading: restarting,
      disabled: restarting,
    },
    start: {
      visible: operation === 'start' || (!running && idle),
      loading: operation === 'start',
      disabled: operation === 'start',
    },
    stop: {
      visible: operation === 'stop' || (idle && running),
      loading: operation === 'stop',
      disabled: operation === 'stop',
    },
  };
}

// Autostart is a symlink, independent of whether the service runs, so it is never gated.
export function getAutostartControlsPresentation({
  enabled,
  enableLoading,
  disableLoading,
  known = true,
}: {
  enabled: boolean;
  enableLoading: boolean;
  disableLoading: boolean;
  known?: boolean;
}) {
  // Same reason: an empty store reads as "autostart is off".
  if (!known) {
    const hidden = { visible: false, loading: false, disabled: true };
    return { enable: { ...hidden }, disable: { ...hidden } };
  }

  return {
    enable: {
      visible: !enabled,
      loading: enableLoading,
      disabled: enableLoading,
    },
    disable: {
      visible: enabled,
      loading: disableLoading,
      disabled: disableLoading,
    },
  };
}

export function hasLocalMutatingServiceActionLoading(
  actions: DiagnosticServiceActions,
) {
  return (
    actions.restart.loading ||
    actions.start.loading ||
    actions.stop.loading ||
    actions.enable.loading ||
    actions.disable.loading
  );
}

// Diagnostics matter most when the service is down; they wait only for the page to know what to
// check and for a start, stop or apply to end, since its end would discard their result.
export function shouldDisableDiagnosticRunAction({
  capabilitiesLoaded,
  operation,
}: {
  capabilitiesLoaded: boolean;
  operation: ServiceOperation | null;
}) {
  return !capabilitiesLoaded || operation !== null;
}

// Only for an action the router never took up; one that ran and failed is in the log, which
// raises it as an alert.
const SERVICE_ACTION_FAILURE_LABELS: Record<string, () => string> = {
  start: () => _('Failed to start the service'),
  stop: () => _('Failed to stop the service'),
  restart: () => _('Failed to restart the service'),
};

export function serviceActionFailureMessage(action: string): string {
  const label = SERVICE_ACTION_FAILURE_LABELS[action];
  return label ? label() : _('Service action failed');
}
