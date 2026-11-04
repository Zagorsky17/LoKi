import { E } from '../../../../helpers/element';
import {
  renderCopyIcon24,
  renderLoaderCircleIcon24,
  renderRotateCcwIcon24,
} from '../../../../icons';
import { Loki } from '../../../types';
import { renderFlagEmojis } from './renderFlagEmojis';

export interface ExitPanelState {
  loading: boolean;
  report?: Loki.GetClashApiProxyExit;
  error?: string;
}

interface IRenderExitPanelProps {
  state: ExitPanelState;
  // The node the answer came through, or the section's choice while the first answer is awaited.
  nodeName?: string;
  onRefresh: () => void;
  onCopy: (address: string) => void;
}

// Cloudflare's loc is an ISO 3166 code, XX when it cannot place the address and T1 for Tor.
export function describeCountry(
  code?: string,
): { flag: string; name: string } | undefined {
  if (!code || code === 'XX') {
    return undefined;
  }
  if (code === 'T1') {
    return { flag: '', name: 'Tor' };
  }
  if (!/^[A-Z]{2}$/.test(code)) {
    return { flag: '', name: code };
  }

  const flag = String.fromCodePoint(
    ...[...code].map((letter) => 0x1f1e6 + letter.charCodeAt(0) - 65),
  );
  let name = code;
  try {
    const lang =
      typeof document === 'undefined' ? '' : document.documentElement?.lang;
    name =
      new Intl.DisplayNames(lang ? [lang] : [], { type: 'region' }).of(code) ||
      code;
  } catch {
    // A runtime without region names shows the code.
  }
  return { flag, name };
}

function renderCountry(code?: string) {
  const country = describeCountry(code);
  if (!country) {
    return undefined;
  }

  return E('span', { class: 'fkp_dashboard-page__exit-panel__country' }, [
    ...renderFlagEmojis(country.flag),
    E('span', { title: code }, country.name),
  ]);
}

function renderAddressRow(
  label: string,
  family: Loki.ClashApiExitAddress,
  onCopy: (address: string) => void,
) {
  const address = family.address;

  return [
    E('dt', {}, label),
    E(
      'dd',
      {},
      address
        ? [
            E(
              'span',
              { class: 'fkp_dashboard-page__exit-panel__address' },
              address,
            ),
            E(
              'button',
              {
                type: 'button',
                class: 'btn fkp_dashboard-page__exit-panel__icon-button',
                title: _('Copy address'),
                'aria-label': _('Copy address'),
                click: () => onCopy(address),
              },
              renderCopyIcon24(),
            ),
          ]
        : E(
            'span',
            {
              class: 'fkp_dashboard-page__exit-panel__missing',
              title: family.error || undefined,
            },
            _('no answer'),
          ),
    ),
  ];
}

// The country row names the IPv4 exit's country, and the IPv6 one's as well when it differs.
function renderCountryRow(report: Loki.GetClashApiProxyExit) {
  const primary = report.ipv4.address ? report.ipv4 : report.ipv6;
  const country = renderCountry(primary.country);
  if (!country) {
    return [];
  }

  const ipv6Country =
    primary === report.ipv4 &&
    report.ipv6.address &&
    report.ipv6.country !== report.ipv4.country
      ? renderCountry(report.ipv6.country)
      : undefined;

  return [
    E('dt', {}, _('Country')),
    E('dd', {}, [
      country,
      ...(ipv6Country
        ? [
            E(
              'span',
              { class: 'fkp_dashboard-page__exit-panel__family-note' },
              'IPv6:',
            ),
            ipv6Country,
          ]
        : []),
    ]),
  ];
}

function renderReport(
  report: Loki.GetClashApiProxyExit,
  stale: boolean,
  onCopy: (address: string) => void,
) {
  const lookupAddress = report.ipv4.address || report.ipv6.address;

  return [
    E(
      'dl',
      {
        class: [
          'fkp_dashboard-page__exit-panel__facts',
          stale ? 'fkp_dashboard-page__exit-panel__facts--stale' : '',
        ]
          .filter(Boolean)
          .join(' '),
      },
      [
        ...renderAddressRow('IPv4', report.ipv4, onCopy),
        ...renderAddressRow('IPv6', report.ipv6, onCopy),
        ...renderCountryRow(report),
      ],
    ),
    ...(lookupAddress
      ? [
          E('div', { class: 'fkp_dashboard-page__exit-panel__footer' }, [
            E(
              'a',
              {
                href: `https://ipinfo.io/${lookupAddress}`,
                target: '_blank',
                rel: 'noopener noreferrer',
              },
              `${_('About the address on ipinfo.io')} ↗`,
            ),
          ]),
        ]
      : []),
  ];
}

function renderStatus(state: ExitPanelState) {
  return state.loading
    ? E('div', { class: 'fkp_dashboard-page__exit-panel__status' }, [
        renderLoaderCircleIcon24(),
        E('span', {}, _('Finding the exit…')),
      ])
    : E(
        'div',
        {
          class:
            'fkp_dashboard-page__exit-panel__status fkp_dashboard-page__exit-panel__status--error',
        },
        _('No answer: %s').format(state.error || _('unknown error')),
      );
}

// Clicks stay inside: the panel lives in a header that folds its section on a click.
export function renderExitPanel({
  state,
  nodeName,
  onRefresh,
  onCopy,
}: IRenderExitPanelProps) {
  return E(
    'div',
    {
      class: 'fkp_dashboard-page__exit-panel',
      role: 'dialog',
      'aria-label': _('Exit IP'),
      click: (event: MouseEvent) => event.stopPropagation(),
    },
    [
      E('div', { class: 'fkp_dashboard-page__exit-panel__header' }, [
        E('div', { class: 'fkp_dashboard-page__exit-panel__heading' }, [
          E(
            'span',
            { class: 'fkp_dashboard-page__exit-panel__caption' },
            _('Exit through'),
          ),
          E(
            'span',
            { class: 'fkp_dashboard-page__exit-panel__node' },
            nodeName ? renderFlagEmojis(nodeName) : '…',
          ),
        ]),
        E(
          'button',
          {
            type: 'button',
            class: 'btn fkp_dashboard-page__exit-panel__icon-button',
            title: _('Check again'),
            'aria-label': _('Check again'),
            'aria-busy': state.loading ? 'true' : undefined,
            disabled: state.loading ? true : undefined,
            click: () => onRefresh(),
          },
          state.loading ? renderLoaderCircleIcon24() : renderRotateCcwIcon24(),
        ),
      ]),
      ...(state.report
        ? renderReport(state.report, state.loading, onCopy)
        : [renderStatus(state)]),
    ],
  );
}
