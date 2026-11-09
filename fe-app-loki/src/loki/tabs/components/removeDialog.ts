// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
import { E } from '../../../helpers/element';
import type { StoreType } from '../../services/store.service';

type SystemInfo = Pick<
  StoreType['diagnosticsSystemInfo'],
  'loaded' | 'loki_version' | 'sing_box_version' | 'sing_box_variant'
>;

// What a removal takes, named as install.sh names it; the backend reports a missing core as
// "not installed" and one it could not ask as "unknown".
export function removedPackages(info: SystemInfo): string[] {
  if (!info.loaded) {
    return ['LoKi', 'loki-core'];
  }
  const packages = [info.loki_version ? `LoKi ${info.loki_version}` : 'LoKi'];
  const version = info.sing_box_version;
  if (version === 'not installed') {
    return packages;
  }
  let core = 'loki-core';
  if (version && version !== 'unknown') {
    core += ` ${version}`;
  }
  if (info.sing_box_variant) {
    core += ` (${info.sing_box_variant})`;
  }
  packages.push(core);
  return packages;
}

// The beta removal preserves settings for recovery and a later clean reinstall.
export function renderRemoveDialog(
  packages: string[],
  onRemove: (purge: boolean) => void,
) {
  const remove = E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button cbi-button-negative',
      click: () => {
        ui.hideModal();
        onRemove(false);
      },
    },
    _('Remove'),
  );
  return [
    E(
      'ul',
      {},
      packages.map((name) => E('li', {}, name)),
    ),
    E('div', { class: 'fkp-partial-modal__footer' }, [
      E('span', {}, _('Keep settings')),
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
