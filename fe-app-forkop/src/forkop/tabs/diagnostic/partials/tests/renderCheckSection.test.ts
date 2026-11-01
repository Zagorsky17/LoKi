// Modified for LoKi on 2026-11-01: keep browser traffic observations informational.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { IDiagnosticsChecksStoreItem } from '../../../../services';

interface FakeNode {
  type: string;
  attrs: Record<string, unknown>;
  children: Array<FakeNode | string>;
  appendChild(child: FakeNode): void;
  setAttribute(name: string, value: string): void;
}

function fakeNode(type: string, attrs: unknown, children?: unknown): FakeNode {
  return {
    type,
    attrs: (attrs || {}) as Record<string, unknown>,
    children:
      children === undefined
        ? []
        : Array.isArray(children)
          ? (children as Array<FakeNode | string>)
          : [children as FakeNode | string],
    appendChild(child) {
      this.children.push(child);
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
  };
}

function find(
  node: FakeNode | string,
  className: string,
): FakeNode | undefined {
  if (typeof node === 'string') {
    return undefined;
  }
  if (
    String(node.attrs.class || '')
      .split(' ')
      .includes(className)
  ) {
    return node;
  }
  for (const child of node.children) {
    const found = find(child, className);
    if (found) {
      return found;
    }
  }
  return undefined;
}

function check(
  state: IDiagnosticsChecksStoreItem['state'],
  items: IDiagnosticsChecksStoreItem['items'] = [
    { state: 'success', key: 'Main DNS', value: '77.88.8.8 · 12 ms' },
  ],
): IDiagnosticsChecksStoreItem {
  return {
    code: 'DNS',
    order: 1,
    title: 'DNS',
    description: 'OK',
    state,
    items,
  };
}

async function render(
  props: IDiagnosticsChecksStoreItem,
  options?: { expanded?: boolean; onToggle?: () => void },
) {
  const { renderCheckSection } = await import('../renderCheckSection');
  return renderCheckSection(props, options) as unknown as FakeNode;
}

beforeEach(() => {
  (globalThis as unknown as { E: unknown }).E = fakeNode;
  vi.stubGlobal('document', {
    timeline: { currentTime: 0 },
    createElementNS: (_namespace: string, type: string) => fakeNode(type, {}),
  });
  vi.stubGlobal('window', { getSelection: () => ({ isCollapsed: true }) });
});

describe('a diagnostic check', () => {
  it('renders an informational icon and neutral style while keeping markup-like values as text', async () => {
    const value = '<img src=x onerror=alert(1)>TEST_SECRET';
    const root = await render(
      check('success', [{ state: 'info', key: 'This device', value }]),
    );
    const row = find(root, 'fkp_diagnostic_alert__summary__item--info');
    expect(row).toBeDefined();
    expect(find(row!, 'lucide-info')).toBeDefined();
    const body = find(row!, 'fkp_diagnostic_alert__summary__item__body');
    expect(body?.children[1]).toMatchObject({ type: 'div', children: [value] });
    expect(
      find(root, 'fkp_diagnostic_alert__summary__item--warning'),
    ).toBeUndefined();
    const { styles } = await import('../../styles');
    expect(styles).toMatch(
      /summary__item--info\s*\{[^}]*color:\s*var\(--text-color-medium/,
    );
  });

  it('folds its details away to its header line', async () => {
    const onToggle = vi.fn();
    const folded = await render(check('success'), {
      expanded: false,
      onToggle,
    });
    const open = await render(check('success'), { expanded: true, onToggle });

    expect(find(folded, 'fkp_diagnostic_alert__summary')).toBeUndefined();
    expect(
      find(folded, 'fkp_diagnostic_alert__toggle')?.attrs['aria-expanded'],
    ).toBe('false');
    expect(find(open, 'fkp_diagnostic_alert__summary')).toBeDefined();
    expect(
      find(open, 'fkp_diagnostic_alert__toggle')?.attrs['aria-expanded'],
    ).toBe('true');
  });

  it('folds from anywhere on its header, but not from a text selection', async () => {
    const onToggle = vi.fn();
    const header = find(
      await render(check('warning'), { expanded: true, onToggle }),
      'fkp_diagnostic_alert__header',
    );

    (header?.attrs.click as () => void)();
    expect(onToggle).toHaveBeenCalledOnce();

    vi.stubGlobal('window', { getSelection: () => ({ isCollapsed: false }) });
    (header?.attrs.click as () => void)();
    expect(onToggle).toHaveBeenCalledOnce();
  });

  it('keeps the click on its chevron to itself', async () => {
    const onToggle = vi.fn();
    const toggle = find(
      await render(check('warning'), { expanded: true, onToggle }),
      'fkp_diagnostic_alert__toggle',
    );
    const event = {
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    } as unknown as MouseEvent;

    (toggle?.attrs.click as (event: MouseEvent) => void)(event);

    expect(onToggle).toHaveBeenCalledOnce();
    expect(event.stopPropagation).toHaveBeenCalledOnce();
  });

  it('offers no fold where there is nothing to fold', async () => {
    const root = await render(check('skipped', []), {
      expanded: false,
      onToggle: vi.fn(),
    });

    expect(find(root, 'fkp_diagnostic_alert__toggle')).toBeUndefined();
    expect(
      find(root, 'fkp_diagnostic_alert__header')?.attrs.click,
    ).toBeUndefined();
  });

  it('shows every detail when nobody folds it', async () => {
    const root = await render(check('error'));

    expect(find(root, 'fkp_diagnostic_alert__summary')).toBeDefined();
    expect(find(root, 'fkp_diagnostic_alert__toggle')).toBeUndefined();
  });
});
