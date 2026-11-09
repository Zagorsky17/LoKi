import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Loki } from '../../../../types';

interface FakeNode {
  type: string;
  attrs: Record<string, unknown>;
  children: Array<FakeNode | string>;
}

function fakeE(type: string, attrs?: unknown, children?: unknown): FakeNode {
  return {
    type,
    attrs: (attrs || {}) as Record<string, unknown>,
    children:
      children === undefined
        ? []
        : Array.isArray(children)
          ? (children as Array<FakeNode | string>)
          : [children as FakeNode | string],
  };
}

function findAll(
  node: FakeNode | string,
  predicate: (candidate: FakeNode) => boolean,
): FakeNode[] {
  if (typeof node === 'string') {
    return [];
  }
  return [
    ...(predicate(node) ? [node] : []),
    ...node.children.flatMap((child) => findAll(child, predicate)),
  ];
}

function byClass(node: FakeNode, name: string) {
  return findAll(node, (candidate) =>
    String(candidate.attrs.class || '')
      .split(' ')
      .includes(name),
  );
}

function text(node: FakeNode | string | undefined): string {
  if (node === undefined) {
    return '';
  }
  return typeof node === 'string' ? node : node.children.map(text).join('');
}

function click(node: FakeNode) {
  const event = { stopPropagation: vi.fn(), preventDefault: vi.fn() };
  (node.attrs.click as (event: unknown) => void)(event);
  return event;
}

beforeEach(() => {
  vi.stubGlobal('E', fakeE);
  vi.stubGlobal('document', {
    documentElement: { lang: 'en' },
    timeline: { currentTime: 0 },
    createElementNS: (_namespace: string, type: string) => ({
      ...fakeE(type),
      setAttribute(this: FakeNode, name: string, value: string) {
        this.attrs[name] = value;
      },
      appendChild(this: FakeNode, child: FakeNode) {
        this.children.push(child);
      },
    }),
  });
});

afterEach(() => vi.unstubAllGlobals());

async function render(
  state: {
    loading: boolean;
    report?: Loki.GetClashApiProxyExit;
    error?: string;
  },
  nodeName?: string,
) {
  const { renderExitPanel } = await import('../renderExitPanel');
  const onRefresh = vi.fn();
  const onCopy = vi.fn();
  const panel = renderExitPanel({
    state,
    nodeName,
    onRefresh,
    onCopy,
  }) as unknown as FakeNode;
  return { panel, onRefresh, onCopy };
}

const report: Loki.GetClashApiProxyExit = {
  outbound: 'main-1-out',
  ipv4: { address: '203.0.113.7', country: 'NL' },
  ipv6: { error: 'connection refused' },
};

describe('describeCountry', () => {
  it('turns a Cloudflare location into a flag and a region name', async () => {
    const { describeCountry } = await import('../renderExitPanel');

    expect(describeCountry('NL')).toEqual({
      flag: '🇳🇱',
      name: 'Netherlands',
    });
    expect(describeCountry('T1')).toEqual({ flag: '', name: 'Tor' });
    expect(describeCountry('XX')).toBeUndefined();
    expect(describeCountry(undefined)).toBeUndefined();
  });
});

describe('renderExitPanel', () => {
  it('shows each family, the country and a lookup link, and copies an address', async () => {
    const { panel, onCopy, onRefresh } = await render(
      { loading: false, report },
      '🇳🇱 Amsterdam',
    );

    expect(
      text(byClass(panel, 'fkp_dashboard-page__exit-panel__node')[0]),
    ).toBe('🇳🇱 Amsterdam');
    const facts = byClass(panel, 'fkp_dashboard-page__exit-panel__facts')[0];
    expect(findAll(facts, (node) => node.type === 'dt').map(text)).toEqual([
      'IPv4',
      'IPv6',
      'Country',
    ]);
    expect(
      byClass(panel, 'fkp_dashboard-page__exit-panel__address').map(text),
    ).toEqual(['203.0.113.7']);
    const missing = byClass(panel, 'fkp_dashboard-page__exit-panel__missing');
    expect(missing.map(text)).toEqual(['no answer']);
    expect(missing[0].attrs.title).toBe('connection refused');
    expect(
      text(byClass(panel, 'fkp_dashboard-page__exit-panel__country')[0]),
    ).toBe('🇳🇱Netherlands');
    expect(
      findAll(panel, (node) => node.type === 'a').map(
        (link) => link.attrs.href,
      ),
    ).toEqual(['https://ipinfo.io/203.0.113.7']);

    const [refresh, copy] = byClass(
      panel,
      'fkp_dashboard-page__exit-panel__icon-button',
    );
    click(copy);
    expect(onCopy).toHaveBeenCalledWith('203.0.113.7');
    click(refresh);
    expect(onRefresh).toHaveBeenCalledOnce();
  });

  it('keeps clicks inside, away from the header that folds the section', async () => {
    const { panel } = await render({ loading: false, report });

    expect(click(panel).stopPropagation).toHaveBeenCalledOnce();
  });

  it('names the IPv6 country beside the IPv4 one when they differ', async () => {
    const { panel } = await render({
      loading: false,
      report: {
        ...report,
        ipv6: { address: '2001:db8::7', country: 'DE' },
      },
    });

    const rows = findAll(panel, (node) => node.type === 'dd');
    const country = rows[rows.length - 1];
    expect(text(country)).toBe('🇳🇱NetherlandsIPv6:🇩🇪Germany');
  });

  it('takes the country and the lookup address from IPv6 when only IPv6 answered', async () => {
    const { panel } = await render({
      loading: false,
      report: {
        outbound: 'main-1-out',
        ipv4: { error: 'Timeout' },
        ipv6: { address: '2001:db8::7', country: 'DE' },
      },
    });

    expect(
      text(byClass(panel, 'fkp_dashboard-page__exit-panel__country')[0]),
    ).toBe('🇩🇪Germany');
    expect(findAll(panel, (node) => node.type === 'a')[0].attrs.href).toBe(
      'https://ipinfo.io/2001:db8::7',
    );
  });

  it('waits with a disabled refresh, and dims a previous answer while checking again', async () => {
    const first = await render({ loading: true }, '🇳🇱 Amsterdam');
    expect(
      text(byClass(first.panel, 'fkp_dashboard-page__exit-panel__status')[0]),
    ).toBe('Finding the exit…');
    const refresh = byClass(
      first.panel,
      'fkp_dashboard-page__exit-panel__icon-button',
    )[0];
    expect(refresh.attrs.disabled).toBe(true);
    expect(refresh.attrs['aria-busy']).toBe('true');

    const again = await render({ loading: true, report });
    expect(
      byClass(again.panel, 'fkp_dashboard-page__exit-panel__facts--stale'),
    ).toHaveLength(1);
  });

  it('says why no family answered', async () => {
    const { panel } = await render({ loading: false, error: 'Timeout' });

    expect(
      text(byClass(panel, 'fkp_dashboard-page__exit-panel__status--error')[0]),
    ).toBe('No answer: Timeout');
  });
});
