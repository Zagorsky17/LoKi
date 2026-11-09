import { E } from '../../../helpers/element';

export function render() {
  return E(
    'div',
    {
      id: 'monitoring-status',
      class: 'fkp_monitoring-page',
    },
    [
      E('div', { class: 'fkp_monitoring-page__panel' }, [
        E('div', { class: 'fkp_monitoring-page__controls' }, [
          E('div', { class: 'fkp_monitoring-page__filters' }, [
            E(
              'select',
              {
                id: 'monitoring-device-filter',
                class: 'cbi-input-select',
              },
              [E('option', { value: '' }, _('All devices'))],
            ),
            E(
              'select',
              {
                id: 'monitoring-route-filter',
                class: 'cbi-input-select',
              },
              [E('option', { value: '' }, _('All routes'))],
            ),
            E('label', { class: 'fkp_monitoring-page__search' }, [
              E('span', { class: 'fkp_monitoring-page__search-icon' }, []),
              E('input', {
                id: 'monitoring-search',
                class: 'cbi-input-text fkp_monitoring-page__search-input',
                type: 'search',
                placeholder: _('Search'),
                autocomplete: 'off',
              }),
            ]),
          ]),
          E('div', { class: 'fkp_monitoring-page__actions' }, [
            E('label', { class: 'fkp_monitoring-page__checkbox' }, [
              E('input', {
                id: 'monitoring-auto-refresh',
                class: 'cbi-input-checkbox',
                type: 'checkbox',
                checked: true,
              }),
              E('span', {}, _('Auto refresh')),
            ]),
            E(
              'button',
              {
                id: 'monitoring-close-all',
                class:
                  'btn cbi-button cbi-button-negative fkp_monitoring-page__action',
                title: _('Close all connections'),
                type: 'button',
                disabled: true,
              },
              _('Close all'),
            ),
          ]),
        ]),
        E('ul', { class: 'cbi-tabmenu fkp_monitoring-page__tabs' }, [
          E('li', { id: 'monitoring-tab-active', class: 'cbi-tab' }, [
            E('a', { href: '#' }, _('Active')),
          ]),
          E('li', { id: 'monitoring-tab-closed', class: 'cbi-tab-disabled' }, [
            E('a', { href: '#' }, _('Closed')),
          ]),
          E(
            'span',
            {
              id: 'monitoring-pause-note',
              class: 'fkp_monitoring-page__pause-note',
              role: 'status',
              title: _('Paused while text is selected'),
              hidden: true,
            },
            _('Paused while text is selected'),
          ),
        ]),
        E(
          'div',
          { id: 'monitoring-connections', class: 'fkp_monitoring-page__body' },
          [
            E(
              'div',
              {
                class:
                  'fkp_monitoring-page__state fkp_monitoring-page__state--loading',
              },
              _('Loading connections...'),
            ),
          ],
        ),
      ]),
    ],
  );
}
