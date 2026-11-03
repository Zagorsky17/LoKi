// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
import { E } from '../../../helpers/element';
import type { StoreType } from '../../services/store.service';

type SystemInfo = Pick<
  StoreType['diagnosticsSystemInfo'],
  'loaded' | 'forkop_version' | 'sing_box_version' | 'sing_box_variant'
>;

// What a removal takes, named as install.sh names it; the backend reports a missing core as
// "not installed" and one it could not ask as "unknown".
export function removedPackages(info: SystemInfo): string[] {
  if (!info.loaded) {
    return ['LoKi', 'sing-box-forkop'];
  }
  const packages = [
    info.forkop_version ? `LoKi ${info.forkop_version}` : 'LoKi',
  ];
  const version = info.sing_box_version;
  if (version === 'not installed') {
    return packages;
  }
  let core = 'sing-box-forkop';
  if (version && version !== 'unknown') {
    core += ` ${version}`;
  }
  if (info.sing_box_variant) {
    core += ` (${info.sing_box_variant})`;
  }
  packages.push(core);
  return packages;
}

// The option stands beside the buttons, as in the page's log window; the buttons wrap together.
export function renderRemoveDialog(
  packages: string[],
  onRemove: (purge: boolean) => void,
) {
  const keep = E('input', {
    type: 'checkbox',
    class: 'cbi-input-checkbox',
  }) as HTMLInputElement;
  keep.checked = true;
  const remove = E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button cbi-button-negative',
      click: () => {
        ui.hideModal();
        onRemove(!keep.checked);
      },
    },
    _('Remove'),
  );
  keep.addEventListener('change', () =>
    remove.replaceChildren(
      keep.checked ? _('Remove') : _('Remove with settings'),
    ),
  );
  return [
    E(
      'ul',
      {},
      packages.map((name) => E('li', {}, name)),
    ),
    E('div', { class: 'fkp-partial-modal__footer' }, [
      E('label', { class: 'fkp-partial-modal__checkbox' }, [
        keep,
        E(
          'span',
          { class: 'fkp-partial-modal__checkbox-text' },
          _('Keep settings'),
        ),
      ]),
      E('div', { class: 'fkp_components-page__remove-buttons' }, [
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button',
            click: () => ui.hideModal(),
          },
          _('Cancel'),
        ),
        remove,
      ]),
    ]),
  ];
}
