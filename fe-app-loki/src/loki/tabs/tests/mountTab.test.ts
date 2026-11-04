import { beforeEach, describe, expect, it, vi } from 'vitest';
import { mountTab, resetMountedTabs } from '../mountTab';

function fakeNode(text: string) {
  return { textContent: text } as unknown as HTMLElement;
}

describe('mountTab', () => {
  beforeEach(() => {
    resetMountedTabs();
  });

  it('hands the form the same node every time it rebuilds', () => {
    const render = vi.fn(() => fakeNode('Loading logs'));
    const initController = vi.fn();

    const first = mountTab('logs', render, initController);
    const second = mountTab('logs', render, initController);

    expect(second).toBe(first);
    expect(render).toHaveBeenCalledTimes(1);
    expect(initController).toHaveBeenCalledTimes(2);
  });

  it('keeps what the controller wrote into the node across a rebuild', () => {
    const render = () => fakeNode('Loading logs');

    const node = mountTab('logs', render, () => undefined);
    node.textContent = 'user.notice loki: [info] Configuration applied';

    expect(mountTab('logs', render, () => undefined).textContent).toBe(
      'user.notice loki: [info] Configuration applied',
    );
  });

  it('keeps one node per tab', () => {
    const render = () => fakeNode('');

    expect(mountTab('logs', render, () => undefined)).not.toBe(
      mountTab('monitoring', render, () => undefined),
    );
  });

  it('reports what the controller threw without losing the node', () => {
    const render = vi.fn(() => fakeNode('Loading logs'));
    const node = mountTab('logs', render, () => {
      throw new Error('controller failed');
    });

    expect(mountTab('logs', render, () => undefined)).toBe(node);
    expect(render).toHaveBeenCalledTimes(1);
  });

  it('reports a controller that fails after it started', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});

    mountTab(
      'dashboard',
      () => fakeNode(''),
      async () => {
        await Promise.resolve();
        throw new Error('render failed');
      },
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(error).toHaveBeenCalledWith(
      '[TABS] Failed to start the dashboard controller',
      expect.any(Error),
    );
    error.mockRestore();
  });
});
