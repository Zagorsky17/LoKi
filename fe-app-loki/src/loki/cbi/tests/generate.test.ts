import { afterEach, describe, expect, it, vi } from 'vitest';

import { addGenerateButton, randomHex } from '../generate';

vi.mock('../../../icons', () => ({ renderRotateCcwIcon24: () => ({}) }));

afterEach(() => vi.unstubAllGlobals());

describe('the Clash API secret generator', () => {
  it('encodes bytes supplied by the cryptographic generator', () => {
    const getRandomValues = vi.fn((bytes: Uint8Array) => {
      bytes.set([0, 15, 128, 255]);
      return bytes;
    });
    vi.stubGlobal('window', { crypto: { getRandomValues } });
    expect(randomHex(4)).toBe('000f80ff');
    expect(getRandomValues).toHaveBeenCalledOnce();
  });

  it('does not replace a failed cryptographic generator with weak randomness', () => {
    vi.stubGlobal('window', {
      crypto: {
        getRandomValues: () => {
          throw new Error('unavailable');
        },
      },
    });
    expect(() => randomHex(16)).toThrow('unavailable');
  });
});

describe('the shared generation button', () => {
  function render(readonly = false) {
    const listeners = new Map<string, (event: Event) => void>();
    const widget = {
      getValue: () => 'old',
      setValue: vi.fn(),
      triggerValidation: vi.fn(),
    };
    const input = { tagName: 'INPUT', dispatchEvent: vi.fn() };
    vi.stubGlobal('dom', { findClassInstance: () => widget });
    vi.stubGlobal('_', (value: string) => value);
    vi.stubGlobal('E', (tag: string, _attrs: unknown, children: unknown) => ({
      tag,
      children,
      addEventListener: (name: string, handler: (event: Event) => void) =>
        listeners.set(name, handler),
    }));
    const option = {
      map: { readonly },
      renderWidget: () => input,
    } as unknown as CBIOption;
    const generate = vi.fn((): string | null => 'new');
    addGenerateButton(option, generate);
    option.renderWidget?.('settings', '', '');
    const click = () =>
      listeners.get('click')?.({
        preventDefault() {},
        stopPropagation() {},
      } as Event);
    return { generate, widget, input, click };
  }

  it('updates and validates the field as if the value were typed', () => {
    const { generate, widget, input, click } = render();
    click();
    expect(generate).toHaveBeenCalledWith('settings', 'old');
    expect(widget.setValue).toHaveBeenCalledWith('new');
    expect(widget.triggerValidation).toHaveBeenCalledOnce();
    expect(input.dispatchEvent).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'change', bubbles: true }),
    );
  });

  it('leaves the current secret intact if generation fails', () => {
    const { generate, widget, input, click } = render();
    generate.mockImplementation(() => {
      throw new Error('unavailable');
    });
    expect(click).toThrow('unavailable');
    expect(widget.setValue).not.toHaveBeenCalled();
    expect(widget.triggerValidation).not.toHaveBeenCalled();
    expect(input.dispatchEvent).not.toHaveBeenCalled();
  });

  it('does not erase the current secret when generation returns no value', () => {
    const { generate, widget, input, click } = render();
    generate.mockReturnValue(null);
    click();
    expect(widget.setValue).not.toHaveBeenCalled();
    expect(widget.triggerValidation).not.toHaveBeenCalled();
    expect(input.dispatchEvent).not.toHaveBeenCalled();
  });

  it('cannot change a field on a read-only form', () => {
    const { generate, widget, input, click } = render(true);
    click();
    expect(generate).not.toHaveBeenCalled();
    expect(widget.setValue).not.toHaveBeenCalled();
    expect(input.dispatchEvent).not.toHaveBeenCalled();
  });
});
