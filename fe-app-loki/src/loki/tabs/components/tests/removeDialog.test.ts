import { beforeEach, describe, expect, it, vi } from 'vitest';
import { removedPackages, renderRemoveDialog } from '../removeDialog';

interface FakeNode {
  type: string;
  attrs: Record<string, unknown>;
  children: Array<FakeNode | string>;
  listeners: Record<string, () => void>;
  checked?: boolean;
  replaceChildren(...nodes: Array<FakeNode | string>): void;
  addEventListener(type: string, listener: () => void): void;
}

function fakeNode(type: string, attrs?: unknown, children?: unknown): FakeNode {
  return {
    type,
    attrs: (attrs || {}) as Record<string, unknown>,
    children:
      children === undefined
        ? []
        : Array.isArray(children)
          ? (children as Array<FakeNode | string>)
          : [children as FakeNode | string],
    listeners: {},
    replaceChildren(...nodes) {
      this.children = nodes;
    },
    addEventListener(type, listener) {
      this.listeners[type] = listener;
    },
  };
}

const textOf = (node: FakeNode | string): string =>
  typeof node === 'string' ? node : node.children.map(textOf).join('');

function find(
  nodes: Array<FakeNode | string>,
  test: (node: FakeNode) => boolean,
): FakeNode {
  for (const node of nodes) {
    if (typeof node === 'string') {
      continue;
    }
    if (test(node)) {
      return node;
    }
    const found = find(node.children, test) as FakeNode | undefined;
    if (found) {
      return found;
    }
  }
  return undefined as unknown as FakeNode;
}

const button = (nodes: Array<FakeNode | string>, text: string) =>
  find(nodes, (node) => node.type === 'button' && textOf(node) === text);

const info = (overrides: Record<string, unknown> = {}) => ({
  loaded: true,
  loki_version: '2.0.0',
  sing_box_version: '1.14.4-r1',
  sing_box_variant: 'base',
  ...overrides,
});

describe('what a removal names', () => {
  it('names Loki and the core by version, the core with its build', () => {
    expect(removedPackages(info())).toEqual([
      'LoKi 2.0.0',
      'loki-core 1.14.4-r1 (base)',
    ]);
  });

  it('leaves out a core that is not there and versions not known', () => {
    expect(
      removedPackages(info({ sing_box_version: 'not installed' })),
    ).toEqual(['LoKi 2.0.0']);
    expect(
      removedPackages(
        info({ sing_box_version: 'unknown', sing_box_variant: '' }),
      ),
    ).toEqual(['LoKi 2.0.0', 'loki-core']);
    expect(removedPackages(info({ loaded: false }))).toEqual([
      'LoKi',
      'loki-core',
    ]);
  });
});

describe('the removal dialog', () => {
  const ui = (globalThis as unknown as { ui: { hideModal: () => void } }).ui;
  let onRemove: ReturnType<typeof vi.fn>;
  let nodes: Array<FakeNode | string>;

  beforeEach(() => {
    (globalThis as unknown as { E: unknown }).E = fakeNode;
    ui.hideModal = vi.fn();
    onRemove = vi.fn();
    nodes = renderRemoveDialog(
      ['LoKi 2.0.0', 'loki-core 1.14.4-r1 (base)'],
      onRemove,
    ) as unknown as Array<FakeNode | string>;
  });

  it('lists what goes', () => {
    const list = find(nodes, (node) => node.type === 'ul');
    expect(list.children.map(textOf)).toEqual([
      'LoKi 2.0.0',
      'loki-core 1.14.4-r1 (base)',
    ]);
  });

  it('keeps the settings when removing the packages', () => {
    (button(nodes, 'Remove').attrs.click as () => void)();
    expect(ui.hideModal).toHaveBeenCalled();
    expect(onRemove).toHaveBeenCalledWith(false);
  });

  it('does not offer destructive configuration removal', () => {
    expect(find(nodes, (node) => node.type === 'input')).toBeUndefined();
    expect(button(nodes, 'Remove with settings')).toBeUndefined();
    expect(nodes.map(textOf).join('')).toContain('Keep settings');
  });

  it('removes nothing on Cancel', () => {
    (button(nodes, 'Cancel').attrs.click as () => void)();
    expect(ui.hideModal).toHaveBeenCalled();
    expect(onRemove).not.toHaveBeenCalled();
  });
});
