// Modified for LoKi on 2026-11-01: keep browser traffic observations informational.
import type {
  IDiagnosticsChecksItem,
  IDiagnosticsChecksStoreItem,
} from '../../../services';

type ItemState = IDiagnosticsChecksItem['state'];

export type CheckOutcome = Pick<
  IDiagnosticsChecksStoreItem,
  'state' | 'description' | 'items'
>;

const SEVERITY: Record<Exclude<ItemState, 'info'>, number> = {
  success: 0,
  warning: 1,
  error: 2,
};

export function finding(
  state: ItemState,
  key: string,
  value: string,
): IDiagnosticsChecksItem {
  return { state, key, value };
}

// A group takes the state of its worst finding.
export function summarize(
  items: IDiagnosticsChecksItem[],
): Pick<IDiagnosticsChecksStoreItem, 'state' | 'description'> {
  const state = items.reduce<Exclude<ItemState, 'info'>>(
    (worst, item) =>
      item.state !== 'info' && SEVERITY[item.state] > SEVERITY[worst]
        ? item.state
        : worst,
    'success',
  );

  return {
    state,
    description:
      state === 'error'
        ? _('Checks failed')
        : state === 'warning'
          ? _('Issues detected')
          : _('Checks passed'),
  };
}

export function outcome(items: IDiagnosticsChecksItem[]): CheckOutcome {
  return { ...summarize(items), items };
}

export function skipped(description: string): CheckOutcome {
  return { state: 'skipped', description, items: [] };
}

// The call itself failed: the router said nothing about what it checks.
export function unanswered(): CheckOutcome {
  return {
    state: 'error',
    description: _('Could not get the check results'),
    items: [],
  };
}

export function formatMs(ms: number) {
  return _('%d ms').format(ms);
}

export function formatMegabytes(kilobytes: number) {
  return _('%d MB').format(Math.round(kilobytes / 1024));
}
