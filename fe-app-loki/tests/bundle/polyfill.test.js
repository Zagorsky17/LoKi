import { afterEach, expect, it } from 'vitest';

import { loadBundle } from '../lib/bundle.js';

const native = globalThis.structuredClone;

afterEach(() => {
  globalThis.structuredClone = native;
});

it('loads in a browser without structuredClone', () => {
  delete globalThis.structuredClone;
  expect(() => loadBundle()).not.toThrow();
  expect(globalThis.structuredClone({ a: [1] })).toEqual({ a: [1] });
});
