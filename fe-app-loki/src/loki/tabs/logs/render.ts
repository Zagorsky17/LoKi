// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
import { E } from '../../../helpers/element';

function renderActionButton(id: string, label: string) {
  return E(
    'button',
    {
      id,
      class: 'btn cbi-button',
      type: 'button',
      title: label,
    },
    label,
  );
}

export function render() {
  return E('div', { id: 'logs-status', class: 'fkp_logs-page' }, [
    E('div', { class: 'fkp_logs-page__toolbar' }, [
      E('div', { class: 'fkp_logs-page__controls' }, [
        E('label', { class: 'fkp_logs-page__search' }, [
          E('span', { class: 'fkp_logs-page__search-icon' }, []),
          E('input', {
            id: 'logs-search',
            class: 'cbi-input-text fkp_logs-page__search-input',
            type: 'search',
            placeholder: _('Search'),
            autocomplete: 'off',
          }),
        ]),
        E('label', { class: 'fkp_logs-page__checkbox' }, [
          E('input', {
            id: 'logs-auto-refresh',
            class: 'cbi-input-checkbox',
            type: 'checkbox',
            checked: true,
          }),
          E('span', {}, _('Auto refresh')),
        ]),
      ]),
      E('div', { class: 'fkp_logs-page__actions' }, [
        renderActionButton('logs-copy', _('Copy')),
        renderActionButton('logs-download', _('Download')),
      ]),
    ]),
    E(
      'pre',
      {
        id: 'logs-output',
        class: 'fkp_logs-page__output fkp_logs-page__output--empty',
        tabIndex: 0,
        role: 'log',
        'aria-label': _('LoKi system logs'),
        'aria-busy': 'true',
      },
      _('Loading logs...'),
    ),
  ]);
}
