import { expect, it, vi } from 'vitest';
import { renderUpdateCheck, renderUpdateDialog } from '../updateCheck';

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

it('distinguishes no updates from failure and never renders release markup', () => {
  (globalThis as unknown as { E: unknown }).E = fakeNode;
  const result = {
    schema: 1 as const,
    success: true as const,
    available: false,
    installed: { app: '2.0.0', core: '1.14.4-r3', variant: 'base' },
    latest: { app: '2.0.0', core: '1.14.4-r3' },
  };
  const text = (nodes: unknown) =>
    (nodes as Array<FakeNode | string>).map(textOf).join(' ');
  expect(text(renderUpdateCheck(result))).toContain('No updates available');
  expect(text(renderUpdateCheck({ ...result, available: true }))).toContain(
    'Updates are available',
  );
  expect(
    text(
      renderUpdateCheck({ schema: 1, success: false, reason: '<img src=x>' }),
    ),
  ).toContain('Update check failed');
  expect(
    text(renderUpdateCheck({ schema: 1, success: false, reason: 'network' })),
  ).not.toContain('No updates');
  const onUpdate = vi.fn();
  const nodes = renderUpdateDialog(
    { ...result, available: true },
    onUpdate,
  ) as unknown as Array<FakeNode | string>;
  expect(onUpdate).not.toHaveBeenCalled();
  (
    find(nodes, (node) => node.type === 'button' && textOf(node) === 'Cancel')
      .attrs.click as () => void
  )();
  expect(onUpdate).not.toHaveBeenCalled();
  (
    find(
      nodes,
      (node) => node.type === 'button' && textOf(node) === 'Update LoKi',
    ).attrs.click as () => void
  )();
  expect(onUpdate).toHaveBeenCalledOnce();
});
