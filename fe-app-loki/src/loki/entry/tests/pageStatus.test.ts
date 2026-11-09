import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { store } from '../../services/store.service';
import { createPageStatus, renderPageStatus } from '../pageStatus';

function element(tag: string) {
  const node = {
    tag,
    className: '',
    children: [] as unknown[],
    replaceChildren(...children: unknown[]) {
      node.children = children;
    },
  };
  return node;
}

beforeAll(() => {
  vi.stubGlobal('document', { createElement: element });
});
afterAll(() => vi.unstubAllGlobals());

function state(
  loading: boolean,
  failed: boolean,
  running: number,
  busy: 'apply' | null = null,
) {
  return {
    loading,
    failed,
    data: {
      singbox: running,
      lokiRunning: running,
      lokiEnabled: 1,
      lokiBusy: busy,
    },
  };
}

describe('the service state in the heading', () => {
  it('is a dot in the colour of the state and the state in words', () => {
    const node = element('small');
    renderPageStatus(node as unknown as HTMLElement, state(false, false, 1));
    expect(node.className).toBe('fkp_page-status fkp_page-status--success');
    expect(node.children).toEqual([
      expect.objectContaining({
        tag: 'span',
        className: 'fkp_page-status__dot',
      }),
      'running',
    ]);

    renderPageStatus(
      node as unknown as HTMLElement,
      state(false, false, 1, 'apply'),
    );
    expect(node.className).toBe('fkp_page-status fkp_page-status--progress');
    expect(node.children[1]).toBe('applying...');
  });

  it('says nothing about a state the page has not read', () => {
    for (const unknown of [state(true, false, 0), state(false, true, 0)]) {
      const node = element('small');
      node.className = 'stale';
      node.children = ['running'];
      renderPageStatus(node as unknown as HTMLElement, unknown);
      expect([node.className, node.children]).toEqual(['', []]);
    }
  });

  it('keeps following the service state in the node it was created as', () => {
    store.set({ serviceState: state(false, false, 0) });
    const node = createPageStatus() as unknown as ReturnType<typeof element>;
    expect(node.className).toBe('fkp_page-status fkp_page-status--error');

    store.set({ serviceState: state(false, false, 1) });
    expect(node.className).toBe('fkp_page-status fkp_page-status--success');
    expect(node.children[1]).toBe('running');
  });
});
