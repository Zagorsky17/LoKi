import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';

import { pageTitle } from '../pageTitle';

beforeAll(() => {
  vi.stubGlobal('document', {
    createElement: (tag: string) => ({ tag, textContent: '' }),
  });
});
afterAll(() => vi.unstubAllGlobals());

const status = { tag: 'small' } as unknown as HTMLElement;

describe('the page title', () => {
  it('names the product and the version of the page, then the service state', () => {
    expect(pageTitle('1.0.6', status)).toEqual([
      'LoKi ',
      { tag: 'small', textContent: '1.0.6' },
      ' ',
      status,
    ]);
  });

  it('shows no version a development build does not have', () => {
    expect(pageTitle('__COMPILED_VERSION_VARIABLE__', status)).toEqual([
      'LoKi ',
      status,
    ]);
  });

  it('carries the status node itself, not markup LuCI would build anew', () => {
    expect(pageTitle('1.0.6', status)[3]).toBe(status);
  });
});
