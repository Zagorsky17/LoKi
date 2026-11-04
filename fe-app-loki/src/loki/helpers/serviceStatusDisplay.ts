import type { Loki } from '../types';

type ServiceStatusTone = 'success' | 'error' | 'progress';

interface ServiceStatusDisplay {
  label: string;
  tone: ServiceStatusTone;
}

const BUSY_LABELS: Record<Loki.ServiceBusy, () => string> = {
  start: () => _('starting...'),
  stop: () => _('stopping...'),
  restart: () => _('restarting...'),
  apply: () => _('applying...'),
  install: () => _('installer running...'),
};

// While an operation runs, readiness is briefly false by design, so the operation is reported
// instead of running or stopped.
export function getServiceStatusDisplay({
  running,
  busy,
}: {
  running: boolean;
  busy?: Loki.ServiceBusy | null;
}): ServiceStatusDisplay {
  if (busy) {
    return { label: BUSY_LABELS[busy](), tone: 'progress' };
  }

  return running
    ? { label: _('running'), tone: 'success' }
    : { label: _('stopped'), tone: 'error' };
}
