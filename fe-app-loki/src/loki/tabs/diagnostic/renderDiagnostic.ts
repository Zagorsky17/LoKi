// The controls come first, so on a narrow screen the check list does not stand above them.

import { E } from '../../../helpers/element';
export function render() {
  return E('div', { id: 'diagnostic-status', class: 'fkp_diagnostic-page' }, [
    E('div', { class: 'fkp_diagnostic-page__controls' }, [
      E('div', { id: 'fkp_diagnostic-page-actions' }),
      E('div', { id: 'fkp_diagnostic-page-system-info' }),
    ]),
    E('div', { class: 'fkp_diagnostic-page__results' }, [
      E('div', { id: 'fkp_diagnostic-page-run-check' }),
      E('div', {
        class: 'fkp_diagnostic-page__checks',
        id: 'fkp_diagnostic-page-checks',
      }),
    ]),
  ]);
}
