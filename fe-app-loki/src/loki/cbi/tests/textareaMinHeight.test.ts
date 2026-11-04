import { describe, expect, it } from 'vitest';

import { configureTextareaOption } from '../annotatedTextarea';

function textarea() {
  const attributes = new Map<string, string>();
  const listeners = new Map<string, () => void>();
  const field = {
    offsetHeight: 0,
    style: { height: '', minHeight: '' } as Record<string, string>,
    getAttribute: (name: string) => attributes.get(name) ?? null,
    setAttribute: (name: string, value: string) => attributes.set(name, value),
    hasAttribute: (name: string) => attributes.has(name),
    addEventListener: (type: string, listener: () => void) =>
      listeners.set(type, listener),
    fire: (type: string) => listeners.get(type)?.(),
  };
  return field;
}

function rendered() {
  const field = textarea();
  const option = { renderWidget: () => field } as unknown as CBIOption;
  configureTextareaOption(option);
  option.renderWidget('section', 'section', '');
  return field;
}

describe('the least height of a textarea', () => {
  it('is the height its rows give it, measured once it shows', () => {
    const field = rendered();
    field.offsetHeight = 82;
    field.fire('focus');
    expect(field.style.minHeight).toBe('82px');
  });

  it('stays the height of its rows after it has been dragged taller', () => {
    const field = rendered();
    field.offsetHeight = 82;
    field.fire('pointerdown');
    field.style.height = '200px';
    field.offsetHeight = 200;
    field.fire('pointerdown');
    field.fire('focus');
    expect(field.style.minHeight).toBe('82px');
  });

  it('is measured before the first drag of a field that was hidden', () => {
    const field = rendered();
    field.fire('focus');
    field.offsetHeight = 82;
    field.fire('pointerdown');
    field.style.height = '200px';
    field.offsetHeight = 200;
    field.fire('pointerdown');
    expect(field.style.minHeight).toBe('82px');
  });
});
