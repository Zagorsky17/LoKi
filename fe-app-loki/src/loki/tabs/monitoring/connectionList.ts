import { E } from '../../../helpers/element';
import { renderChevronUpIcon24, renderXIcon24 } from '../../../icons';
import { sourceLabel } from './source';

export type ConnectionSortColumn = 'time' | 'download' | 'upload';

export interface ConnectionListSort {
  column: ConnectionSortColumn;
  descending: boolean;
}

interface ConnectionListOptions {
  closable: boolean;
  sort?: ConnectionListSort | null;
}

export interface ConnectionListItem {
  id: string;
  host: string;
  sourceName: string;
  sourceDetail: string;
  system: boolean;
  route: string;
  direct: boolean;
  network: string;
  time: string;
  download: string;
  upload: string;
  closing: boolean;
}

// Divs with table roles rather than a <table>: footstrap claims any <table> with a header row and
// restyles it with !important rules nothing outside its cascade layers can override. Closed
// connections get no close column.
function renderList(
  rows: HTMLElement[],
  { closable, sort }: ConnectionListOptions,
) {
  return E(
    'div',
    {
      class: [
        'fkp_monitoring-page__list',
        closable ? 'fkp_monitoring-page__list--closable' : '',
      ]
        .filter(Boolean)
        .join(' '),
      role: 'table',
    },
    [
      E(
        'div',
        {
          class: 'fkp_monitoring-page__row fkp_monitoring-page__row--head',
          role: 'row',
        },
        [
          renderHeading('host', _('Host')),
          renderHeading('source', _('Source')),
          renderHeading('route', _('Route')),
          renderHeading('network', _('Type')),
          renderSortHeading('time', _('Time'), sort),
          renderSortHeading('download', `↓ ${_('Downloaded')}`, sort),
          renderSortHeading('upload', `↑ ${_('Uploaded')}`, sort),
          ...(closable
            ? [
                E('div', {
                  class: cellClass('action'),
                  role: 'columnheader',
                  'aria-label': _('Close'),
                }),
              ]
            : []),
        ],
      ),
      ...rows,
    ],
  );
}

function cellClass(column: string) {
  return `fkp_monitoring-page__cell fkp_monitoring-page__cell--${column}`;
}

function renderHeading(column: string, text: string) {
  return E('div', { class: cellClass(column), role: 'columnheader' }, text);
}

// Every sortable heading carries the arrow, shown only on the sorted one, so a column keeps its
// width when the sort moves.
function renderSortHeading(
  column: ConnectionSortColumn,
  text: string,
  sort?: ConnectionListSort | null,
) {
  const order =
    sort?.column === column
      ? sort.descending
        ? 'descending'
        : 'ascending'
      : '';

  return E(
    'div',
    {
      class: cellClass(column),
      role: 'columnheader',
      ...(order ? { 'aria-sort': order } : {}),
    },
    [
      E(
        'button',
        { class: 'fkp_monitoring-page__sort', type: 'button', value: column },
        [text, renderChevronUpIcon24()],
      ),
    ],
  );
}

function renderCell(column: string, children: Node[]) {
  return E('div', { class: cellClass(column), role: 'cell' }, children);
}

function renderValue(text: string, className = '') {
  const value = text || '-';

  return E(
    'span',
    {
      class: ['fkp_monitoring-page__value', className]
        .filter(Boolean)
        .join(' '),
      title: value,
      'data-copy-value': value,
    },
    value,
  );
}

// The direct route and the router itself are no section and no device, so they are drawn unlike
// the names the user gave, which they could share.
function renderBuiltin(text: string, title: string) {
  return E(
    'span',
    {
      class:
        'fkp_monitoring-page__value fkp_monitoring-page__tag fkp_monitoring-page__tag--builtin',
      title,
      'data-copy-value': text,
    },
    text,
  );
}

// The muted colour sets the name apart; a tooltip has none, so it keeps the filter's separator.
function renderSource({
  sourceName: name,
  sourceDetail: detail,
  system,
}: ConnectionListItem) {
  if (system) {
    return renderBuiltin(
      name,
      _('The router itself: its services and programs'),
    );
  }

  const shown = [name, detail].filter(Boolean).join(' ') || '-';
  const muted = (text: string) =>
    E('span', { class: 'fkp_monitoring-page__muted' }, text);

  return E(
    'span',
    {
      class: 'fkp_monitoring-page__value',
      title: sourceLabel(name, detail) || shown,
      'data-copy-value': shown,
    },
    name ? [name, ...(detail ? [' ', muted(detail)] : [])] : [muted(shown)],
  );
}

function renderRoute({ route, direct }: ConnectionListItem) {
  return direct
    ? renderBuiltin(route, _('Straight from the router, without a proxy'))
    : renderValue(route, 'fkp_monitoring-page__tag');
}

function renderAction(item: ConnectionListItem) {
  return E(
    'button',
    {
      class: 'btn cbi-button fkp_monitoring-page__row-action',
      title: _('Close connection'),
      'aria-label': _('Close connection'),
      type: 'button',
      value: item.id,
      ...(item.closing ? { disabled: true } : {}),
    },
    [renderXIcon24()],
  );
}

function renderRow(item: ConnectionListItem, closable: boolean) {
  return E(
    'div',
    {
      class: [
        'fkp_monitoring-page__row',
        item.closing ? 'fkp_monitoring-page__row--closing' : '',
      ]
        .filter(Boolean)
        .join(' '),
      role: 'row',
    },
    [
      renderCell('host', [renderValue(item.host)]),
      renderCell('source', [renderSource(item)]),
      renderCell('route', [renderRoute(item)]),
      renderCell('network', [
        renderValue(item.network, 'fkp_monitoring-page__network'),
      ]),
      renderCell('time', [renderValue(item.time)]),
      renderCell('download', [renderValue(item.download)]),
      renderCell('upload', [renderValue(item.upload)]),
      ...(closable ? [renderCell('action', [renderAction(item)])] : []),
    ],
  );
}

export function renderConnectionList(
  items: ConnectionListItem[],
  options: ConnectionListOptions,
) {
  return renderList(
    items.map((item) => renderRow(item, options.closable)),
    options,
  );
}

export function renderConnectionListState(
  text: string,
  options: ConnectionListOptions & { className?: string },
) {
  return renderList(
    [
      E(
        'div',
        {
          class: 'fkp_monitoring-page__row fkp_monitoring-page__row--state',
          role: 'row',
        },
        [
          E(
            'div',
            {
              class: ['fkp_monitoring-page__state', options.className]
                .filter(Boolean)
                .join(' '),
              role: 'cell',
            },
            text,
          ),
        ],
      ),
    ],
    options,
  );
}
