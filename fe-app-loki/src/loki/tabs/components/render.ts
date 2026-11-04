// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
import { E } from '../../../helpers/element';

// The controller starts with the form, before LuCI puts the node into the document.
export let pageRoot: HTMLElement | null = null;

function versionRow(name: string, id: string) {
  return E('div', { class: 'fkp_components-page__version' }, [
    E('b', {}, name),
    E('div', { id }),
  ]);
}

// The controls come first, so on a narrow screen the terminal stands below them.
export function render() {
  pageRoot = E(
    'div',
    { id: 'components-status', class: 'fkp_components-page' },
    [
      E('div', { class: 'fkp_components-page__controls' }, [
        E(
          'div',
          {
            class:
              'fkp_components-page__block fkp_components-page__block--versions',
          },
          [
            E('b', {}, _('Installed versions')),
            versionRow('LoKi', 'components-loki-version'),
            versionRow('loki-core', 'components-core-version'),
          ],
        ),
        E('div', {
          id: 'components-update-check',
          class: 'fkp_components-page__block',
        }),
        E('div', {
          id: 'components-actions',
          class: 'fkp_components-page__block',
        }),
        E('div', {
          id: 'components-config',
          class: 'fkp_components-page__block',
        }),
      ]),
      E('div', { id: 'components-run', class: 'fkp_components-page__run' }),
    ],
  );
  return pageRoot;
}
