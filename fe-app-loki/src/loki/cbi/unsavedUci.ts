import { LOKI_UCI_PACKAGE } from '../../constants';

// What uci.js holds in uci.state for the Loki package until the next save pushes it: added
// sections, set and deleted options, and the order a drag left the rows in.
export interface UnsavedUci {
  values: unknown;
  creates: unknown;
  changes: unknown;
  deletes: unknown;
  reorder: boolean;
  order: Record<string, unknown>;
}

function copy(value: unknown) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

export function captureUnsavedUci(): UnsavedUci {
  const state = uci.state;
  const values = state.values[LOKI_UCI_PACKAGE] || {};

  return {
    values: state.values[LOKI_UCI_PACKAGE],
    creates: copy(state.creates[LOKI_UCI_PACKAGE]),
    changes: copy(state.changes[LOKI_UCI_PACKAGE]),
    deletes: copy(state.deletes[LOKI_UCI_PACKAGE]),
    reorder: state.reorder[LOKI_UCI_PACKAGE] === true,
    order: Object.fromEntries(
      Object.entries(values).map(([sid, section]) => [sid, section['.index']]),
    ),
  };
}

export function restoreUnsavedUci(unsaved: UnsavedUci) {
  const state = uci.state;
  // A save pushed everything and reloaded the package, so nothing captured is left to restore.
  if (state.values[LOKI_UCI_PACKAGE] !== unsaved.values) {
    return;
  }

  const put = (store: Record<string, unknown>, value: unknown) => {
    if (value === undefined) {
      delete store[LOKI_UCI_PACKAGE];
    } else {
      store[LOKI_UCI_PACKAGE] = copy(value);
    }
  };
  put(state.creates, unsaved.creates);
  put(state.changes, unsaved.changes);
  put(state.deletes, unsaved.deletes);
  if (unsaved.reorder) {
    state.reorder[LOKI_UCI_PACKAGE] = true;
  } else {
    delete state.reorder[LOKI_UCI_PACKAGE];
  }
  Object.entries(state.values[LOKI_UCI_PACKAGE] || {}).forEach(
    ([sid, section]) => {
      if (Object.prototype.hasOwnProperty.call(unsaved.order, sid)) {
        section['.index'] = unsaved.order[sid] as number;
      }
    },
  );
}
