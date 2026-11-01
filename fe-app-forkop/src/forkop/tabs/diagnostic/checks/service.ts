// Modified for LoKi on 2026-11-01: report known list overlaps without changing routing.
import { DOMAIN_LIST_OPTIONS } from '../../../../constants';
import { ForkopShellMethods } from '../../../methods';
import type { IDiagnosticsChecksItem } from '../../../services';
import type { Forkop } from '../../../types';
import { formatDuration } from '../../../helpers/formatDuration';
import {
  CheckOutcome,
  finding,
  formatMegabytes,
  outcome,
  unanswered,
} from './present';

// Below this share of free memory the kernel is about to start killing.
const LOW_MEMORY_SHARE = 0.1;

function forkopItem(data: Forkop.ServiceCheckResult) {
  if (data.running) {
    return finding(
      'success',
      'Forkop',
      data.uptime >= 0
        ? _('running for %s').format(formatDuration(data.uptime))
        : _('running'),
    );
  }

  return finding(
    'error',
    'Forkop',
    data.last_error
      ? _('not running: %s').format(data.last_error)
      : _('not running'),
  );
}

// A core that answers no version is one Forkop's start cannot read either: its reason says so.
function coreItem(data: Forkop.ServiceCheckResult) {
  const key = _('Core');
  const { installed, binary, version, variant, outdated, required, problem } =
    data.core;

  if (!installed) {
    return finding('error', key, _('sing-box-forkop is not installed'));
  }
  if (!binary) {
    return finding('error', key, problem);
  }
  if (!version) {
    return finding(
      'error',
      key,
      _('sing-box %s, not sing-box-forkop').format(binary),
    );
  }
  if (outdated) {
    return finding(
      'error',
      key,
      _('sing-box-forkop %s is outdated: %s or newer is needed').format(
        version,
        required,
      ),
    );
  }
  if (problem) {
    return finding('error', key, problem);
  }
  return finding(
    'success',
    key,
    variant
      ? _('sing-box-forkop %s (%s)').format(version, variant)
      : _('sing-box-forkop %s').format(version),
  );
}

function coreLogItem(data: Forkop.ServiceCheckResult) {
  const key = _('Core log');
  const log = data.core_log;
  if (!log?.available) {
    return finding('warning', key, _('Log data unavailable'));
  }
  if (log.limited) {
    return finding(
      'warning',
      key,
      _(
        'At least %s error messages in the last 60 seconds; log data incomplete',
      ).format(log.count),
    );
  }
  return finding(
    log.count > 0 ? 'warning' : 'success',
    key,
    log.count > 0
      ? _('%s error messages found in the last 60 seconds').format(log.count)
      : _('No error messages found in the last 60 seconds'),
  );
}

function conflictItems(data: Forkop.ServiceCheckResult) {
  const key = _('Conflicts');
  const items: IDiagnosticsChecksItem[] = data.conflicts.map((conflict) =>
    conflict.kind === 'tproxy'
      ? finding('error', key, _('%s intercepts traffic').format(conflict.table))
      : finding(
          'error',
          key,
          _('%s takes DNS queries before Forkop').format(conflict.table),
        ),
  );

  if (data.foreign_sing_box.length) {
    items.push(
      finding(
        'error',
        key,
        _('another sing-box is running (PID %s)').format(
          data.foreign_sing_box.join(', '),
        ),
      ),
    );
  }

  return items.length ? items : [finding('success', key, _('none found'))];
}

function listOverlapItems(data: Forkop.ServiceCheckResult) {
  return (data.list_overlaps ?? []).map((overlap) => {
    const builtin =
      (DOMAIN_LIST_OPTIONS as Record<string, string>)[overlap.builtin] ??
      overlap.builtin;
    return finding(
      'warning',
      _('Lists in %s').format(overlap.section),
      (overlap.relation === 'same_source'
        ? _(
            'External list %s uses the same source as %s; review the section lists',
          )
        : _(
            'External list %s may overlap %s; compare domains and subnets before removing a list',
          )
      ).format(overlap.external, builtin),
    );
  });
}

function memoryItem(data: Forkop.ServiceCheckResult) {
  const key = _('Memory');
  const free = _('%s of %s free').format(
    formatMegabytes(data.memory.available_kb),
    formatMegabytes(data.memory.total_kb),
  );

  if (
    data.memory.total_kb > 0 &&
    data.memory.available_kb < data.memory.total_kb * LOW_MEMORY_SHARE
  ) {
    return finding('warning', key, free);
  }

  return finding('success', key, free);
}

export function presentService(
  data: Forkop.ServiceCheckResult,
): IDiagnosticsChecksItem[] {
  return [
    forkopItem(data),
    coreItem(data),
    coreLogItem(data),
    ...conflictItems(data),
    ...listOverlapItems(data),
    memoryItem(data),
  ];
}

// A failed call says nothing about the service, so the runtime checks still try.
export async function runServiceCheck(): Promise<{
  result: CheckOutcome;
  running: boolean;
  data?: Forkop.ServiceCheckResult;
}> {
  const response = await ForkopShellMethods.checkService();

  if (!response.success) {
    return { result: unanswered(), running: true };
  }

  return {
    result: outcome(presentService(response.data)),
    running: response.data.running,
    data: response.data,
  };
}
