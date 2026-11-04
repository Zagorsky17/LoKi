import { describe, expect, it, vi } from 'vitest';

import type { ConnectionListItem, ConnectionListSort } from '../connectionList';

interface Drawn {
  tag: string;
  attrs: Record<string, unknown>;
  children: Array<Drawn | string>;
}

vi.stubGlobal(
  'E',
  (
    tag: string,
    attrs: Record<string, unknown> = {},
    children: unknown = [],
  ) => ({
    tag,
    attrs,
    children: Array.isArray(children) ? children : [children],
  }),
);
vi.mock('../../../../icons', () => ({
  renderChevronUpIcon24: () => ({ tag: 'svg', attrs: {}, children: [] }),
  renderXIcon24: () => ({ tag: 'svg', attrs: {}, children: [] }),
}));

const { renderConnectionList, renderConnectionListState } = await import(
  '../connectionList'
);

const draw = (node: unknown) => node as Drawn;

function elements(node: Drawn): Drawn[] {
  return [
    node,
    ...node.children.flatMap((child) =>
      typeof child === 'string' ? [] : elements(child),
    ),
  ];
}

function text(node: Drawn): string {
  return node.children
    .map((child) => (typeof child === 'string' ? child : text(child)))
    .join('');
}

function withRole(node: Drawn, role: string) {
  return elements(node).filter((element) => element.attrs.role === role);
}

function classes(node: Drawn): string[] {
  return String(node.attrs.class ?? '').split(/\s+/);
}

function isCloseButton(node: Drawn) {
  return classes(node).includes('fkp_monitoring-page__row-action');
}

const CONNECTION: ConnectionListItem = {
  id: 'c-1',
  host: 'g.whatsapp.net:5222',
  sourceName: 'POCO-F7',
  sourceDetail: '192.168.1.144',
  system: false,
  route: 'Proxy',
  direct: false,
  network: 'tcp',
  time: '0:40',
  download: '2.46 KB',
  upload: '2.19 KB',
  closing: false,
};

describe('the Monitoring connection list', () => {
  it('is nothing a theme can claim as a data table', () => {
    const list = draw(renderConnectionList([CONNECTION], { closable: true }));

    expect(
      elements(list).filter(
        (element) =>
          ['table', 'thead', 'tbody', 'tr', 'th', 'td'].includes(element.tag) ||
          classes(element).includes('table'),
      ),
    ).toEqual([]);
    expect(list.attrs.role).toBe('table');
  });

  it('puts every value under the heading of its column', () => {
    const list = draw(renderConnectionList([CONNECTION], { closable: true }));
    const [head, row] = withRole(list, 'row');

    expect(withRole(head, 'columnheader').map(text)).toEqual([
      'Host',
      'Source',
      'Route',
      'Type',
      'Time',
      '↓ Downloaded',
      '↑ Uploaded',
      '',
    ]);
    expect(withRole(row, 'cell').map(text)).toEqual([
      'g.whatsapp.net:5222',
      'POCO-F7 192.168.1.144',
      'Proxy',
      'tcp',
      '0:40',
      '2.46 KB',
      '2.19 KB',
      '',
    ]);
  });

  it('sorts by time and traffic from their headings and marks the sorted one', () => {
    const headings = (sort: ConnectionListSort | null) =>
      withRole(
        withRole(
          draw(renderConnectionList([CONNECTION], { closable: true, sort })),
          'row',
        )[0],
        'columnheader',
      );
    const buttonValue = (heading: Drawn) =>
      elements(heading).find((element) => element.tag === 'button')?.attrs
        .value ?? '';
    const order = (heading: Drawn) => heading.attrs['aria-sort'] ?? '';

    expect(headings(null).map(buttonValue)).toEqual([
      '',
      '',
      '',
      '',
      'time',
      'download',
      'upload',
      '',
    ]);
    expect(headings(null).map(order)).toEqual(Array(8).fill(''));
    expect(
      headings({ column: 'download', descending: true }).map(order),
    ).toEqual(['', '', '', '', '', 'descending', '', '']);
    expect(headings({ column: 'time', descending: false }).map(order)).toEqual([
      '',
      '',
      '',
      '',
      'ascending',
      '',
      '',
      '',
    ]);
  });

  it('closes a connection by its id, once', () => {
    const [open, closing] = [
      CONNECTION,
      { ...CONNECTION, id: 'c-2', closing: true },
    ].map((item) =>
      elements(draw(renderConnectionList([item], { closable: true }))).find(
        isCloseButton,
      ),
    );

    expect(open?.attrs.value).toBe('c-1');
    expect(open?.attrs.disabled).toBeUndefined();
    expect(closing?.attrs.value).toBe('c-2');
    expect(closing?.attrs.disabled).toBe(true);
  });

  it('has no column to close a connection that is already closed', () => {
    const list = draw(renderConnectionList([CONNECTION], { closable: false }));
    const [head, row] = withRole(list, 'row');

    expect(elements(list).some(isCloseButton)).toBe(false);
    expect(withRole(head, 'columnheader')).toHaveLength(7);
    expect(withRole(row, 'cell').map(text)).not.toContain('-');
    expect(withRole(row, 'cell')).toHaveLength(7);
    expect(classes(list)).not.toContain('fkp_monitoring-page__list--closable');
  });

  function sourceValues(items: ConnectionListItem[]) {
    return withRole(
      draw(renderConnectionList(items, { closable: true })),
      'cell',
    )
      .filter((cell) =>
        classes(cell).includes('fkp_monitoring-page__cell--source'),
      )
      .map((cell) => draw(cell.children[0]));
  }

  function mutedText(node: Drawn) {
    return elements(node)
      .filter((element) =>
        classes(element).includes('fkp_monitoring-page__muted'),
      )
      .map(text)
      .join('');
  }

  it('shows the name and mutes what it belongs to', () => {
    const [client, device, bare, unknown] = sourceValues([
      { ...CONNECTION, sourceName: 'alice', sourceDetail: 'Office' },
      CONNECTION,
      { ...CONNECTION, sourceName: '', sourceDetail: '192.168.1.101' },
      { ...CONNECTION, sourceName: '', sourceDetail: '' },
    ]);

    expect([client, device, bare, unknown].map(text)).toEqual([
      'alice Office',
      'POCO-F7 192.168.1.144',
      '192.168.1.101',
      '-',
    ]);
    expect([client, device, bare].map(mutedText)).toEqual([
      'Office',
      '192.168.1.144',
      '192.168.1.101',
    ]);
  });

  it('separates the detail in plain text and copies the source as it reads', () => {
    const values = sourceValues([
      { ...CONNECTION, sourceName: 'mom phone', sourceDetail: 'Server #2' },
      { ...CONNECTION, sourceName: '', sourceDetail: '192.168.1.101' },
      { ...CONNECTION, sourceName: '', sourceDetail: '' },
    ]);

    expect(values.map((value) => value.attrs.title)).toEqual([
      'mom phone · Server #2',
      '192.168.1.101',
      '-',
    ]);
    expect(values.map((value) => value.attrs['data-copy-value'])).toEqual([
      'mom phone Server #2',
      '192.168.1.101',
      '-',
    ]);
  });

  it('draws the router itself like the direct route and says what it is', () => {
    const [device, system] = sourceValues([
      { ...CONNECTION, sourceName: 'System', sourceDetail: '192.168.1.53' },
      { ...CONNECTION, sourceName: 'System', sourceDetail: '', system: true },
    ]);

    expect(classes(device)).not.toContain('fkp_monitoring-page__tag--builtin');
    expect(classes(system)).toContain('fkp_monitoring-page__tag--builtin');
    expect([text(system), system.attrs['data-copy-value']]).toEqual([
      'System',
      'System',
    ]);
    expect(system.attrs.title).toBe(
      'The router itself: its services and programs',
    );
  });

  it('draws the direct route unlike a section and says what it means', () => {
    const [section, direct] = withRole(
      draw(
        renderConnectionList(
          [CONNECTION, { ...CONNECTION, route: 'Direct', direct: true }],
          { closable: true },
        ),
      ),
      'cell',
    )
      .filter((cell) =>
        classes(cell).includes('fkp_monitoring-page__cell--route'),
      )
      .map((cell) => draw(cell.children[0]));

    expect(classes(section)).not.toContain('fkp_monitoring-page__tag--builtin');
    expect(classes(direct)).toContain('fkp_monitoring-page__tag--builtin');
    expect([text(direct), direct.attrs['data-copy-value']]).toEqual([
      'Direct',
      'Direct',
    ]);
    expect(direct.attrs.title).toBe(
      'Straight from the router, without a proxy',
    );
  });

  it('says what it is waiting for in a row of its own', () => {
    const list = draw(
      renderConnectionListState('Loading connections...', { closable: false }),
    );
    const rows = withRole(list, 'row');

    expect(rows).toHaveLength(2);
    expect(withRole(rows[1], 'cell').map(text)).toEqual([
      'Loading connections...',
    ]);
  });
});
