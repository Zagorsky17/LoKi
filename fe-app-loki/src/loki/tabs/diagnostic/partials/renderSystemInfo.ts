import { E } from '../../../../helpers/element';

interface IRenderSystemInfoRow {
  key: string;
  value: string;
  badge?: string;
}

interface IRenderSystemInfoProps {
  items: Array<IRenderSystemInfoRow>;
}

export function renderSystemInfo({ items }: IRenderSystemInfoProps) {
  return E('div', { class: 'fkp_diagnostic-page__controls__system-info' }, [
    E(
      'b',
      { class: 'fkp_diagnostic-page__controls__system-info__title' },
      _('System information'),
    ),
    ...items.map((item) =>
      E('div', { class: 'fkp_diagnostic-page__controls__system-info__row' }, [
        E('b', {}, item.key),
        E('div', {}, [
          E('span', {}, item.value),
          ...(item.badge
            ? [
                E(
                  'span',
                  {
                    class: 'fkp_diagnostic-page__controls__system-info__badge',
                  },
                  item.badge,
                ),
              ]
            : []),
        ]),
      ]),
    ),
  ]);
}
