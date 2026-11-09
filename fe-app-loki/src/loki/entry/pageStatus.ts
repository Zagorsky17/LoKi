import { getServiceStatusDisplay } from '../helpers/serviceStatusDisplay';
import { store } from '../services/store.service';
import type { StoreType } from '../services/store.service';

// A state the page has not read, or could not read, is left unsaid.
export function renderPageStatus(
  node: HTMLElement,
  state: StoreType['serviceState'],
) {
  if (state.loading || state.failed) {
    node.className = '';
    node.replaceChildren();
    return;
  }

  const display = getServiceStatusDisplay({
    running: Boolean(state.data.lokiRunning),
    busy: state.data.lokiBusy,
  });
  const dot = document.createElement('span');
  dot.className = 'fkp_page-status__dot';

  node.className = `fkp_page-status fkp_page-status--${display.tone}`;
  node.replaceChildren(dot, display.label);
}

export function createPageStatus() {
  const node = document.createElement('small');
  renderPageStatus(node, store.get().serviceState);
  store.subscribeKey('serviceState', (state) => renderPageStatus(node, state));
  return node;
}
