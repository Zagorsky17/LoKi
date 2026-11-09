import { afterEach, describe, expect, it } from 'vitest';

import { getRuleEditButtonText } from '../grid';

const globals = globalThis as unknown as Record<string, unknown>;
const translate = globals._;

afterEach(() => {
  globals._ = translate;
});

describe('the row action label', () => {
  it('is Edit when the catalog has no answer', () => {
    globals._ = (key: string) => key;
    expect(getRuleEditButtonText()).toBe('Edit');
  });

  it('is the translation when the catalog has one', () => {
    globals._ = () => 'Изменить';
    expect(getRuleEditButtonText()).toBe('Изменить');
  });
});
