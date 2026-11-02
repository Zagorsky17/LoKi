import { afterEach, describe, expect, it, vi } from 'vitest';
import { Forkop } from '../../../types';

interface FakeNode {
  type: string;
  attrs: Record<string, unknown>;
  children: Array<FakeNode | string>;
}

function installElementFactory() {
  const fakeE = (type: string, attrs?: unknown, children?: unknown) => ({
    type,
    attrs: (attrs || {}) as Record<string, unknown>,
    children:
      children === undefined
        ? []
        : Array.isArray(children)
          ? (children as Array<FakeNode | string>)
          : [children as FakeNode | string],
  });
  (globalThis as unknown as { E: unknown }).E = fakeE;
  if (typeof document === 'undefined') {
    vi.stubGlobal('document', {
      timeline: { currentTime: 0 },
      createElementNS: (_namespace: string, type: string) => ({
        ...fakeE(type, {}),
        setAttribute(this: FakeNode, name: string, value: string) {
          this.attrs[name] = value;
        },
        appendChild(this: FakeNode, child: FakeNode) {
          this.children.push(child);
        },
      }),
    });
  }
}

function findNode(
  node: FakeNode | string,
  predicate: (candidate: FakeNode) => boolean,
): FakeNode | undefined {
  if (typeof node === 'string') {
    return undefined;
  }

  if (predicate(node)) {
    return node;
  }

  for (const child of node.children) {
    const found = findNode(child, predicate);
    if (found) {
      return found;
    }
  }

  return undefined;
}

function findNodes(
  node: FakeNode | string,
  predicate: (candidate: FakeNode) => boolean,
): FakeNode[] {
  if (typeof node === 'string') {
    return [];
  }

  return [
    ...(predicate(node) ? [node] : []),
    ...node.children.flatMap((child) => findNodes(child, predicate)),
  ];
}

describe('renderSections latency actions', () => {
  it('tests the clicked outbound instead of the selector group', async () => {
    vi.stubGlobal(
      'MutationObserver',
      class {
        observe() {}
      },
    );
    vi.stubGlobal('document', {
      body: {},
      querySelectorAll: () => [],
      querySelector: () => null,
      createElementNS: (_namespace: string, type: string) => ({
        type,
        attrs: {},
        children: [] as Array<FakeNode | string>,
        setAttribute(name: string, value: string) {
          (this.attrs as Record<string, string>)[name] = value;
        },
        appendChild(child: FakeNode) {
          this.children.push(child);
        },
      }),
    });
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const onTestLatency = vi.fn();
    const onTestOutboundLatency = vi.fn();
    const section: Forkop.OutboundGroup = {
      code: 'proxy-out',
      sectionName: 'main',
      displayName: 'Main',
      withTagSelect: true,
      outbounds: [
        {
          code: 'main/Node',
          displayName: 'Node',
          latency: 0,
          type: 'VLESS',
          selected: false,
        },
      ],
    };

    const root = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency,
      onTestOutboundLatency,
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
    const button = findNode(
      root,
      (node) =>
        node.type === 'button' &&
        String(node.attrs.class || '').includes(
          'fkp_dashboard-page__outbound-grid__item__latency',
        ),
    );

    expect(button).toBeDefined();
    const event = {
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    } as unknown as MouseEvent;
    (button?.attrs.click as (event: MouseEvent) => void)(event);

    expect(onTestOutboundLatency).toHaveBeenCalledWith('proxy', 'main/Node');
    expect(onTestLatency).not.toHaveBeenCalled();
    expect(event.preventDefault).toHaveBeenCalledOnce();
    expect(event.stopPropagation).toHaveBeenCalledOnce();
  }, 15000);

  it('toggles temporary latency sorting for multi-card sections', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const onSortByLatencyChange = vi.fn();
    const outbound = (
      displayName: string,
      latency: number,
      type = 'VLESS',
    ): Forkop.Outbound => ({
      code: displayName.toLowerCase(),
      displayName,
      latency,
      type,
      selected: false,
    });
    const outbounds: Forkop.Outbound[] = [
      outbound('Missing', 0),
      outbound('Fallback', 200, 'Fallback'),
      outbound('Node', 50),
      outbound('URLTest', 100, 'URLTest'),
    ];
    const render = (sortByLatency = false) =>
      renderSections({
        loading: false,
        failed: false,
        section: {
          code: 'main-out',
          sectionName: 'main',
          displayName: 'Main',
          withTagSelect: true,
          outbounds,
        },
        onTestLatency: vi.fn(),
        onTestOutboundLatency: vi.fn(),
        onChooseOutbound: vi.fn(),
        onCopyOutbound: vi.fn(),
        onShowUrlTestInfo: vi.fn(),
        onShowFallbackInfo: vi.fn(),

        onSortByLatencyChange,
        sortByLatency,
        latencyFetching: false,
      }) as unknown as FakeNode;
    const findSortButton = (root: FakeNode) =>
      findNode(
        root,
        (node) =>
          node.type === 'button' &&
          String(node.attrs.class || '')
            .split(' ')
            .includes('fkp_dashboard-page__outbound-section__sort-by-latency'),
      );
    const inactiveRoot = render();
    const inactiveButton = findSortButton(inactiveRoot);
    const event = {
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    } as unknown as MouseEvent;

    expect(inactiveButton?.attrs.title).toBe('Sort by latency');
    expect(inactiveButton?.attrs['aria-label']).toBe('Sort by latency');
    expect(inactiveButton?.attrs['aria-pressed']).toBe('false');
    (inactiveButton?.attrs.click as (event: MouseEvent) => void)(event);
    expect(onSortByLatencyChange).toHaveBeenCalledWith('main', true);
    expect(event.preventDefault).toHaveBeenCalledOnce();
    expect(event.stopPropagation).toHaveBeenCalledOnce();

    const activeRoot = render(true);
    const activeButton = findSortButton(activeRoot);
    const cards = findNodes(activeRoot, (node) =>
      String(node.attrs.class || '')
        .split(' ')
        .includes('fkp_dashboard-page__outbound-grid__item'),
    );
    const names = cards.map(
      (card) => findNode(card, (node) => node.type === 'b')?.children[0],
    );

    expect(names).toEqual(['Node', 'URLTest', 'Fallback', 'Missing']);
    expect(outbounds.map((outbound) => outbound.displayName)).toEqual([
      'Missing',
      'Fallback',
      'Node',
      'URLTest',
    ]);
    expect(activeButton?.attrs['aria-pressed']).toBe('true');
    expect(String(activeButton?.attrs.class)).toContain(
      'fkp_dashboard-page__outbound-section__sort-by-latency--active',
    );

    (activeButton?.attrs.click as (event: MouseEvent) => void)(event);
    expect(onSortByLatencyChange).toHaveBeenLastCalledWith('main', false);

    const singleCardRoot = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'main-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [outbounds[0]],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;

    expect(findSortButton(singleCardRoot)).toBeUndefined();
  }, 15000);

  it('does not choose an outbound when its name is selected', async () => {
    installElementFactory();
    const getSelection = vi.fn(() => ({ isCollapsed: false }));
    vi.stubGlobal('window', { getSelection });
    const { renderSections } = await import('../partials/renderSections');
    const onChooseOutbound = vi.fn();
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [
          {
            code: 'main/Node',
            displayName: 'Node',
            latency: 0,
            type: 'VLESS',
            selected: false,
          },
        ],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound,
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
    const card = findNode(root, (node) =>
      String(node.attrs.class || '')
        .split(' ')
        .includes('fkp_dashboard-page__outbound-grid__item'),
    );
    const click = card?.attrs.click as () => void;

    click();
    expect(onChooseOutbound).not.toHaveBeenCalled();

    getSelection.mockReturnValue({ isCollapsed: true });
    click();
    expect(onChooseOutbound).toHaveBeenCalledWith(
      'main',
      'proxy-out',
      'main/Node',
    );
  }, 15000);

  it('tests a URLTest through its group endpoint', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const onTestOutboundLatency = vi.fn();
    const section: Forkop.OutboundGroup = {
      code: 'proxy-out',
      sectionName: 'main',
      displayName: 'Main',
      withTagSelect: true,
      outbounds: [
        {
          code: 'main/URLTest',
          displayName: 'URLTest',
          latency: 0,
          type: 'URLTest',
          selected: false,
          urlTestInfo: {
            code: 'main/URLTest',
            displayName: 'URLTest',
            selectedCode: 'main/Node 2',
            outbounds: [
              {
                code: 'main/Node 1',
                displayName: 'Node 1',
                latency: 10,
                type: 'VLESS',
                selected: false,
              },
              {
                code: 'main/Node 2',
                displayName: 'Node 2',
                latency: 20,
                type: 'VLESS',
                selected: true,
              },
            ],
          },
        },
      ],
    };

    const root = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onTestOutboundLatency,
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
    const button = findNode(
      root,
      (node) =>
        node.type === 'button' &&
        String(node.attrs.class || '').includes(
          'fkp_dashboard-page__outbound-grid__item__latency',
        ),
    );

    expect(button).toBeDefined();
    const event = {
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    } as unknown as MouseEvent;
    (button?.attrs.click as (event: MouseEvent) => void)(event);

    expect(onTestOutboundLatency).toHaveBeenCalledWith('group', 'main/URLTest');
  }, 15000);

  it('tests a fallback through its group endpoint', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const onTestLatency = vi.fn();
    const onTestOutboundLatency = vi.fn();
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'main-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [
          {
            code: 'main/Fallback',
            displayName: 'Fallback',
            latency: 10,
            type: 'Fallback',
            selected: false,
            fallbackInfo: {
              code: 'main/Fallback',
              displayName: 'Fallback',
              outbounds: [
                {
                  code: 'main/Node 1',
                  displayName: 'Node 1',
                  latency: 10,
                  type: 'VLESS',
                  selected: true,
                  pinned: false,
                  levelIndex: 0,
                  levelName: 'Primary',
                },
                {
                  code: 'main/Node 2',
                  displayName: 'Node 2',
                  latency: 20,
                  type: 'VLESS',
                  selected: false,
                  pinned: false,
                  levelIndex: 1,
                  levelName: 'Backup',
                },
              ],
            },
          },
        ],
      },
      onTestLatency,
      onTestOutboundLatency,
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
    const buttons = findNodes(root, (node) => node.type === 'button');
    const fallbackButton = buttons.find((button) =>
      String(button.attrs.class || '').includes(
        'fkp_dashboard-page__outbound-grid__item__latency',
      ),
    );
    const sectionButton = buttons.find(
      (button) =>
        String(button.attrs.class || '') ===
        'btn dashboard-sections-grid-item-test-latency',
    );
    const event = {
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    } as unknown as MouseEvent;

    (fallbackButton?.attrs.click as (event: MouseEvent) => void)(event);
    expect(onTestOutboundLatency).toHaveBeenCalledWith(
      'group',
      'main/Fallback',
    );
    expect(onTestLatency).not.toHaveBeenCalled();

    (sectionButton?.attrs.click as (event: MouseEvent) => void)(event);
    expect(onTestLatency).toHaveBeenCalledWith('main-out');
  }, 15000);

  it('blocks only the section button during a section latency test', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const onTestLatency = vi.fn();
    const props = {
      loading: false,
      failed: false,
      section: {
        code: 'proxy-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [
          {
            code: 'main/Node',
            displayName: 'Node',
            latency: 1600,
            type: 'VLESS',
            selected: false,
          },
          {
            code: 'main/Other',
            displayName: 'Other',
            latency: 20,
            type: 'VLESS',
            selected: false,
          },
        ],
      },
      onTestLatency,
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: true,
    };
    const root = renderSections(props) as unknown as FakeNode;
    const buttons = findNodes(
      root,
      (node) =>
        node.type === 'button' &&
        String(node.attrs.class || '').includes(
          'fkp_dashboard-page__outbound-grid__item__latency',
        ),
    );
    const sectionButton = findNode(
      root,
      (node) =>
        node.type === 'button' &&
        String(node.attrs.class || '') ===
          'btn dashboard-sections-grid-item-test-latency',
    );
    expect(buttons).toHaveLength(2);
    expect(buttons[0]?.attrs.disabled).toBeUndefined();
    expect(buttons[1]?.attrs.disabled).toBeUndefined();
    expect(buttons[0]?.attrs['aria-busy']).toBeUndefined();
    expect(buttons[1]?.attrs['aria-busy']).toBeUndefined();
    expect(
      sectionButton?.children.some(
        (child) =>
          typeof child !== 'string' &&
          String(child.attrs.class || '').includes('loader-circle'),
      ),
    ).toBe(true);
    expect(sectionButton?.attrs.disabled).toBe(true);
    expect(sectionButton?.attrs['aria-busy']).toBe('true');
    const event = {
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    } as unknown as MouseEvent;
    (sectionButton?.attrs.click as (event: MouseEvent) => void)(event);
    expect(onTestLatency).not.toHaveBeenCalled();
  }, 15000);

  it('blocks only the exact card during an outbound latency test', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [
          {
            code: 'main/URLTest',
            displayName: 'URLTest',
            latency: 0,
            type: 'URLTest',
            selected: false,
            urlTestInfo: {
              code: 'main/URLTest',
              displayName: 'URLTest',
              outbounds: [
                {
                  code: 'main/Node',
                  displayName: 'Node',
                  latency: 0,
                  type: 'VLESS',
                  selected: false,
                },
              ],
            },
          },
          {
            code: 'main/Node',
            displayName: 'Node',
            latency: 0,
            type: 'VLESS',
            selected: false,
          },
        ],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
      latencyFetchingTargets: new Set(['main/URLTest']),
    }) as unknown as FakeNode;
    const buttons = findNodes(
      root,
      (node) =>
        node.type === 'button' &&
        String(node.attrs.class || '').includes(
          'fkp_dashboard-page__outbound-grid__item__latency',
        ),
    );

    expect(buttons).toHaveLength(2);
    expect(buttons[0]?.attrs['aria-busy']).toBe('true');
    expect(buttons[0]?.attrs.disabled).toBe(true);
    expect(buttons[1]?.attrs['aria-busy']).toBeUndefined();
    expect(buttons[1]?.attrs.disabled).toBeUndefined();
    const sectionButton = findNode(
      root,
      (node) =>
        node.type === 'button' &&
        String(node.attrs.class || '') ===
          'btn dashboard-sections-grid-item-test-latency',
    );
    expect(sectionButton?.attrs['aria-busy']).toBeUndefined();
    expect(sectionButton?.attrs.disabled).toBeUndefined();
  }, 15000);

  it('does not render latency or selection actions for an empty group', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const onChooseOutbound = vi.fn();
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [
          {
            code: 'main/Empty',
            displayName: 'Empty',
            latency: 0,
            type: 'URLTest',
            selected: false,
            urlTestInfo: {
              code: 'main/Empty',
              displayName: 'Empty',
              outbounds: [],
            },
          },
        ],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound,
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
    const latency = findNode(
      root,
      (node) =>
        node.type === 'button' &&
        String(node.attrs.class || '').includes(
          'fkp_dashboard-page__outbound-grid__item__latency',
        ),
    );
    const card = findNode(root, (node) =>
      String(node.attrs.class || '')
        .split(' ')
        .includes('fkp_dashboard-page__outbound-grid__item'),
    );

    expect(latency).toBeUndefined();
    expect(String(card?.attrs.class)).toContain(
      'fkp_dashboard-page__outbound-grid__item--disabled',
    );
    (card?.attrs.click as () => void)();
    expect(onChooseOutbound).not.toHaveBeenCalled();
  }, 15000);

  it('keeps the subscription tag as the metadata heading', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [],
        subscriptionMetadata: [
          { title: 'Subscription', subscriptionTag: 'Premium' },
        ],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
    const heading = findNodes(
      root,
      (node) =>
        String(node.attrs.class || '') ===
        'fkp_dashboard-page__subscription-meta__heading',
    )[0];

    expect(heading).toBeTruthy();
    expect(heading.children).toHaveLength(1);
    const tag = (heading.children as FakeNode[])[0] as FakeNode;
    expect(String(tag.attrs.class || '')).toBe(
      'fkp_dashboard-page__outbound-grid__item__subscription-tag',
    );
    expect(tag.children[0]).toBe('Premium');
  });

  it('leaves out the metadata heading without a subscription tag', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [],
        subscriptionMetadata: [{ title: 'Subscription', expire: 1893456000 }],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
    const heading = findNode(
      root,
      (node) =>
        String(node.attrs.class || '') ===
        'fkp_dashboard-page__subscription-meta__heading',
    );
    const title = findNode(
      root,
      (node) =>
        String(node.attrs.class || '') ===
        'fkp_dashboard-page__subscription-meta__title',
    );

    expect(heading).toBeUndefined();
    expect(title?.children[0]).toBe('Subscription');
  });

  it('leaves out a block that would hold nothing but the tag', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [],
        subscriptionMetadata: [
          { subscriptionTag: 'Premium', sourceIndex: 1, sourceSection: 'main' },
        ],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;

    expect(
      findNode(
        root,
        (node) =>
          String(node.attrs.class || '') ===
          'fkp_dashboard-page__subscription-meta',
      ),
    ).toBeUndefined();
  });

  it('keeps a block that has something of its own to say', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [],
        subscriptionMetadata: [
          {
            subscriptionTag: 'Premium',
            sourceIndex: 1,
            sourceSection: 'main',
            supportUrl: 'https://subscription.example/support',
          },
        ],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;

    expect(
      findNode(
        root,
        (node) =>
          String(node.attrs.class || '') ===
          'fkp_dashboard-page__subscription-meta',
      ),
    ).toBeTruthy();
  });
});

describe('renderSections subscription update time', () => {
  const now = Date.UTC(2026, 9, 21, 18, 0, 0);

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  async function render(updatedAt?: number, lang = 'en') {
    vi.useFakeTimers();
    vi.setSystemTime(now);
    installElementFactory();
    vi.stubGlobal('document', { ...document, documentElement: { lang } });
    const { renderSections } = await import('../partials/renderSections');
    return renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [],
        subscriptionMetadata: [{ title: 'Subscription', updatedAt }],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
  }

  const updated = (root: FakeNode) =>
    findNode(
      root,
      (node) =>
        node.type === 'time' &&
        node.attrs.class === 'fkp_dashboard-page__subscription-meta__updated',
    );

  // Looks nodes up by `tag.class` in the rendered tree and writes their text back into it.
  function queryRoot(root: FakeNode) {
    return {
      querySelectorAll: (selector: string) => {
        const [type, className] = selector.split('.');
        return findNodes(
          root,
          (node) => node.type === type && node.attrs.class === className,
        ).map((node) => ({
          get dateTime() {
            return String(node.attrs.dateTime);
          },
          get textContent() {
            return node.children[0];
          },
          set textContent(value) {
            node.children = [value];
          },
        }));
      },
    } as unknown as ParentNode;
  }

  it('says how long ago the core last updated the subscription, and when on hover', async () => {
    const node = updated(await render(now / 1000 - 300));

    expect(node?.children).toEqual(['5 min. ago']);
    expect(node?.attrs.dateTime).toBe('2026-10-21T17:55:00.000Z');
    expect(node?.attrs.title).toMatch(/^Updated .*2026/);
  });

  it('says it in the language of the page', async () => {
    const node = updated(await render(now / 1000 - 7200, 'ru'));

    expect(node?.children).toEqual(['2 ч назад']);
  });

  it('never puts the update ahead of the browser clock', async () => {
    const node = updated(await render(now / 1000 + 120));

    expect(node?.children).toEqual(['this minute']);
  });

  it('leaves the line out of a subscription with no update time', async () => {
    const root = await render(undefined);

    expect(updated(root)).toBeUndefined();
    expect(
      findNode(
        root,
        (node) => node.attrs.class === 'fkp_dashboard-page__subscription-meta',
      ),
    ).toBeTruthy();
  });

  it('keeps the age current without drawing the section again', async () => {
    const root = await render(now / 1000 - 300);
    const { refreshSubscriptionAges } = await import(
      '../partials/renderSections'
    );

    vi.setSystemTime(now + 120000);
    refreshSubscriptionAges(queryRoot(root));

    expect(updated(root)?.children).toEqual(['7 min. ago']);
  });
});

describe('renderSections collapse action', () => {
  const section = {
    code: 'proxy-out',
    sectionName: 'main',
    displayName: 'Main',
    withTagSelect: true,
    outbounds: [
      {
        code: 'main/Node',
        displayName: 'Node',
        latency: 42,
        type: 'VLESS',
        selected: true,
      },
      {
        code: 'main/Other',
        displayName: 'Other',
        latency: 84,
        type: 'VLESS',
        selected: false,
      },
    ],
    subscriptionMetadata: [
      {
        title: 'Subscription',
        traffic: { used: 1024, total: 2048, isUnlimited: false },
      },
    ],
  } as Forkop.OutboundGroup;

  async function render(
    props: {
      collapsible?: boolean;
      collapsed?: boolean;
      onCollapsedChange?: (sectionName: string, collapsed: boolean) => void;
    } = {},
  ) {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    return renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
      ...props,
    }) as unknown as FakeNode;
  }

  const findCollapseButton = (root: FakeNode) =>
    findNode(
      root,
      (node) =>
        node.type === 'button' &&
        String(node.attrs.class || '')
          .split(' ')
          .includes('fkp_dashboard-page__outbound-section__collapse'),
    );

  const childClasses = (root: FakeNode, className: string) =>
    (
      findNode(root, (node) =>
        String(node.attrs.class || '')
          .split(' ')
          .includes(className),
      )?.children || []
    )
      .filter((child): child is FakeNode => typeof child !== 'string')
      .map((child) => String(child.attrs.class || ''));

  it('stays out of a dashboard showing a single section', async () => {
    expect(findCollapseButton(await render())).toBeUndefined();
    expect(
      findCollapseButton(await render({ collapsible: false })),
    ).toBeUndefined();
  });

  it('sits in front of the title once another section shares the page', async () => {
    const root = await render({ collapsible: true });
    const button = findCollapseButton(root);

    expect(button).toBeDefined();
    expect(button?.attrs.title).toBe('Collapse section');
    expect(button?.attrs['aria-label']).toBe('Collapse section');
    expect(button?.attrs['aria-expanded']).toBe('true');
    expect(
      childClasses(root, 'fkp_dashboard-page__outbound-section__heading'),
    ).toEqual([
      expect.stringContaining('fkp_dashboard-page__outbound-section__collapse'),
      'fkp_dashboard-page__outbound-section__title-section__title',
      'fkp_dashboard-page__outbound-section__current',
    ]);
    expect(
      childClasses(
        root,
        'fkp_dashboard-page__outbound-section__title-section__actions',
      ).some((name) => name.includes('outbound-section__collapse')),
    ).toBe(false);
  });

  it('reports the state the click asks for', async () => {
    const onCollapsedChange = vi.fn();
    const event = {
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    } as unknown as MouseEvent;
    const expanded = await render({ collapsible: true, onCollapsedChange });

    (findCollapseButton(expanded)?.attrs.click as (event: MouseEvent) => void)(
      event,
    );
    expect(onCollapsedChange).toHaveBeenCalledWith('main', true);
    expect(event.preventDefault).toHaveBeenCalledOnce();
    expect(event.stopPropagation).toHaveBeenCalledOnce();

    const collapsed = await render({
      collapsible: true,
      collapsed: true,
      onCollapsedChange,
    });
    const collapsedButton = findCollapseButton(collapsed);

    expect(collapsedButton?.attrs.title).toBe('Expand section');
    expect(collapsedButton?.attrs['aria-expanded']).toBe('false');
    expect(String(collapsedButton?.attrs.class)).toContain(
      'fkp_dashboard-page__outbound-section__collapse--collapsed',
    );
    (collapsedButton?.attrs.click as (event: MouseEvent) => void)(event);
    expect(onCollapsedChange).toHaveBeenLastCalledWith('main', false);
  });

  it('folds away every card and subscription block, keeping the title row', async () => {
    const expanded = await render({ collapsible: true });
    const collapsed = await render({ collapsible: true, collapsed: true });
    const count = (root: FakeNode, className: string) =>
      findNodes(root, (node) =>
        String(node.attrs.class || '')
          .split(' ')
          .includes(className),
      ).length;

    expect(count(expanded, 'fkp_dashboard-page__outbound-grid')).toBe(1);
    expect(count(expanded, 'fkp_dashboard-page__outbound-grid__item')).toBe(2);
    expect(count(expanded, 'fkp_dashboard-page__subscription-meta')).toBe(1);

    expect(count(collapsed, 'fkp_dashboard-page__outbound-grid')).toBe(0);
    expect(count(collapsed, 'fkp_dashboard-page__outbound-grid__item')).toBe(0);
    expect(count(collapsed, 'fkp_dashboard-page__subscription-meta')).toBe(0);
    expect(
      findNode(collapsed, (node) =>
        String(node.attrs.class || '').includes(
          'fkp_dashboard-page__outbound-section__title-section__title',
        ),
      )?.children[0],
    ).toBe('Main');
    expect(
      findNode(collapsed, (node) =>
        String(node.attrs.class || '').includes(
          'dashboard-sections-grid-item-test-latency',
        ),
      ),
    ).toBeDefined();
  });
});

describe('renderSections header', () => {
  const node = (code: string, selected: boolean, latency = 0) => ({
    code,
    displayName: code.split('/')[1],
    latency,
    type: 'VLESS',
    selected,
  });

  async function current(
    section: Partial<Forkop.OutboundGroup>,
    collapsed = false,
  ) {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'main-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [],
        ...section,
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
      collapsible: true,
      collapsed,
    }) as unknown as FakeNode;
    const found = findNode(root, (candidate) =>
      String(candidate.attrs.class || '')
        .split(' ')
        .includes('fkp_dashboard-page__outbound-section__current'),
    );
    return found
      ? findNodes(found, () => true)
          .flatMap((candidate) =>
            candidate.children.filter(
              (child): child is string => typeof child === 'string',
            ),
          )
          .join(' ')
      : undefined;
  }

  it('names the node the section chose, with its latency', async () => {
    expect(
      await current({
        outbounds: [node('main/Node', false, 42), node('main/Other', true, 84)],
      }),
    ).toBe('Other 84ms');
    expect(
      await current({
        outbounds: [node('main/Node', true), node('main/Other', false)],
      }),
    ).toBe('Node');
  });

  it('leaves a section of one node to its card until it is folded', async () => {
    const outbounds = [node('main/Only', true, 30)];

    expect(await current({ outbounds })).toBeUndefined();
    expect(await current({ outbounds }, true)).toBe('Only 30ms');
  });

  it('says nothing for a section that has no choice to make', async () => {
    expect(
      await current({
        withTagSelect: false,
        outbounds: [node('main/Node', true, 42), node('main/Other', false)],
      }),
    ).toBeUndefined();
  });

  it('tests the section from an icon that carries its name', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'main-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [node('main/Node', true)],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
    const button = findNode(
      root,
      (candidate) =>
        candidate.type === 'button' &&
        String(candidate.attrs.class || '').includes(
          'dashboard-sections-grid-item-test-latency',
        ),
    );

    expect(button?.attrs['aria-label']).toBe('Test latency');
    expect(button?.attrs.title).toBe('Test latency');
    expect(
      findNodes(button as FakeNode, () => true).some((candidate) =>
        candidate.children.some((child) => typeof child === 'string'),
      ),
    ).toBe(false);
  });

  it('carries no refresh of its own, which the toolbar does for every section', async () => {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'main-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        subscriptionSourceCount: 1,
        subscriptionProviderTags: ['main/sub1'],
        outbounds: [node('main/Node', true), node('main/Other', false)],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
    }) as unknown as FakeNode;
    const labels = findNodes(root, (candidate) => candidate.type === 'button')
      .map((button) =>
        String(button.attrs['aria-label'] || button.attrs.title || ''),
      )
      .filter(Boolean);

    expect(labels).not.toContain('Update subscriptions');
    expect(labels).not.toContain('Update lists');
  });

  async function header(
    props: Partial<{
      collapsible: boolean;
      collapsed: boolean;
      onCollapsedChange: (sectionName: string, collapsed: boolean) => void;
    }>,
  ) {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    const root = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'main-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [node('main/Node', true), node('main/Other', false)],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
      ...props,
    }) as unknown as FakeNode;
    return findNode(root, (candidate) =>
      String(candidate.attrs.class || '')
        .split(' ')
        .includes('fkp_dashboard-page__outbound-section__title-section'),
    ) as FakeNode;
  }

  function select(collapsed: boolean) {
    vi.stubGlobal('window', {
      getSelection: () => ({ isCollapsed: collapsed }),
    });
  }

  it('folds from anywhere on the header, not only from the chevron', async () => {
    const onCollapsedChange = vi.fn();
    select(true);

    (
      (await header({ collapsible: true, onCollapsedChange })).attrs
        .click as () => void
    )();
    (
      (await header({ collapsible: true, collapsed: true, onCollapsedChange }))
        .attrs.click as () => void
    )();

    expect(onCollapsedChange.mock.calls).toEqual([
      ['main', true],
      ['main', false],
    ]);
    expect(
      (await header({ collapsible: false, onCollapsedChange })).attrs.click,
    ).toBeUndefined();
  });

  it('leaves a click that ends a text selection alone', async () => {
    const onCollapsedChange = vi.fn();
    select(false);

    (
      (await header({ collapsible: true, onCollapsedChange })).attrs
        .click as () => void
    )();

    expect(onCollapsedChange).not.toHaveBeenCalled();
  });
});

describe('renderSections exit action', () => {
  async function render(
    props: Partial<
      Parameters<typeof import('../partials/renderSections').renderSections>[0]
    >,
  ) {
    installElementFactory();
    const { renderSections } = await import('../partials/renderSections');
    return renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'main-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [
          {
            code: 'main/Node',
            displayName: 'Node',
            latency: 0,
            type: 'VLESS',
            selected: true,
          },
        ],
      },
      onTestLatency: vi.fn(),
      onTestOutboundLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowFallbackInfo: vi.fn(),

      latencyFetching: false,
      ...props,
    }) as unknown as FakeNode;
  }

  const hasClass = (name: string) => (candidate: FakeNode) =>
    String(candidate.attrs.class || '')
      .split(' ')
      .includes(name);

  it('opens the panel from a header icon without folding the section', async () => {
    const onToggleExit = vi.fn();
    const root = await render({ onToggleExit, collapsible: true });
    const button = findNode(
      root,
      hasClass('fkp_dashboard-page__outbound-section__exit'),
    )!;

    expect(button.attrs['aria-expanded']).toBe('false');
    expect(button.attrs['aria-haspopup']).toBe('dialog');
    const event = { preventDefault: vi.fn(), stopPropagation: vi.fn() };
    (button.attrs.click as (event: unknown) => void)(event);
    expect(onToggleExit).toHaveBeenCalledOnce();
    expect(event.stopPropagation).toHaveBeenCalledOnce();
    expect(
      findNode(root, hasClass('fkp_dashboard-page__exit-panel')),
    ).toBeUndefined();
  });

  it('follows the section name and its choice, apart from the latency test', async () => {
    const root = await render({
      onToggleExit: vi.fn(),
      section: {
        code: 'main-out',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: ['A', 'B'].map((name, index) => ({
          code: `main/${name}`,
          displayName: name,
          latency: 0,
          type: 'VLESS',
          selected: index === 0,
        })),
      },
    });
    const heading = findNode(
      root,
      hasClass('fkp_dashboard-page__outbound-section__heading'),
    )!;
    const classes = heading.children.map((child) =>
      typeof child === 'string' ? child : String(child.attrs.class),
    );

    expect(classes.slice(-2)).toEqual([
      'fkp_dashboard-page__outbound-section__current',
      'btn fkp_dashboard-page__outbound-section__exit',
    ]);
    expect(
      findNode(
        findNode(
          root,
          hasClass(
            'fkp_dashboard-page__outbound-section__title-section__actions',
          ),
        )!,
        hasClass('fkp_dashboard-page__outbound-section__exit'),
      ),
    ).toBeUndefined();
  });

  it('hangs the open panel from the header band', async () => {
    const root = await render({
      onToggleExit: vi.fn(),
      exitPanel: { loading: true, nodeName: 'Node' },
    });
    const header = findNode(
      root,
      hasClass('fkp_dashboard-page__outbound-section__title-section'),
    )!;

    expect(
      findNode(
        header,
        hasClass('fkp_dashboard-page__outbound-section__exit--open'),
      )?.attrs['aria-expanded'],
    ).toBe('true');
    expect(
      findNode(header, hasClass('fkp_dashboard-page__exit-panel')),
    ).toBeDefined();
  });

  it('is left out of a section with no outbound to ask through', async () => {
    const root = await render({
      onToggleExit: vi.fn(),
      section: {
        code: 'vpn-out',
        sectionName: 'vpn',
        displayName: 'VPN',
        withTagSelect: false,
        outbounds: [],
      },
    });

    expect(
      findNode(root, hasClass('fkp_dashboard-page__outbound-section__exit')),
    ).toBeUndefined();
  });
});
