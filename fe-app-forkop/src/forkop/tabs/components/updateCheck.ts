import { E } from '../../../helpers/element';
import type { Forkop } from '../../types';

type SuccessfulCheck = Extract<Forkop.UpdateCheckResult, { success: true }>;

// Release data is text: neither version strings nor error details become markup.
export function renderUpdateCheck(result?: Forkop.UpdateCheckResult | null) {
  if (!result) {
    return [
      E('span', {}, _('Check for updates to see the available versions')),
    ];
  }
  if (!result.success) {
    return [
      E(
        'span',
        {},
        _('Update check failed. See the installer output for the reason.'),
      ),
    ];
  }
  return [
    E(
      'b',
      {},
      result.available ? _('Updates are available') : _('No updates available'),
    ),
    E(
      'span',
      {},
      `LoKi: ${result.installed.app || '—'} → ${result.latest.app}`,
    ),
    E(
      'span',
      {},
      `sing-box-forkop: ${result.installed.core || '—'} → ${result.latest.core}`,
    ),
  ];
}

export function renderUpdateDialog(
  result: SuccessfulCheck,
  onUpdate: () => void,
) {
  return [
    ...renderUpdateCheck(result),
    E(
      'p',
      {},
      _('The installer checks the release again before changing packages.'),
    ),
    E('div', { class: 'fkp-partial-modal__footer' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          click: () => ui.hideModal(),
        },
        _('Cancel'),
      ),
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button cbi-button-apply',
          click: () => {
            ui.hideModal();
            onUpdate();
          },
        },
        _('Update LoKi'),
      ),
    ]),
  ];
}
