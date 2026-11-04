import { describe, expect, it, vi } from 'vitest';

const luciE = vi.fn((...args: unknown[]) => ({ args }));
vi.stubGlobal('E', luciE);

const { E } = await import('../element');

describe('E', () => {
  it('puts a lone string in as text, which LuCI would hand to innerHTML', () => {
    E('div', {}, '<img src=x onerror=alert(1)>');
    expect(luciE).toHaveBeenLastCalledWith('div', {}, [
      '<img src=x onerror=alert(1)>',
    ]);
    E('span', { class: 'count' }, 3 as unknown as string);
    expect(luciE).toHaveBeenLastCalledWith('span', { class: 'count' }, ['3']);
  });

  it('leaves children that already are nodes or lists alone', () => {
    const node = { nodeType: 1 } as unknown as Node;
    E('div', {}, node);
    expect(luciE).toHaveBeenLastCalledWith('div', {}, node);
    E('div', {}, ['a', node]);
    expect(luciE).toHaveBeenLastCalledWith('div', {}, ['a', node]);
    E('div', { class: 'empty' });
    expect(luciE).toHaveBeenLastCalledWith('div', { class: 'empty' });
  });
});
