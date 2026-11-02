import { E } from '../../helpers/element';
import { renderRotateCcwIcon24 } from '../../icons';

function widgetElement(node: HTMLElement): CBIWidget | null {
  const instance = dom.findClassInstance(node) as CBIWidget | null;
  return instance && typeof instance.setValue === 'function' ? instance : null;
}

function controlOf(node: HTMLElement | null): HTMLElement | null {
  if (!node) {
    return null;
  }
  if (/^(INPUT|SELECT|TEXTAREA)$/.test(node.tagName)) {
    return node;
  }
  return typeof node.querySelector === 'function'
    ? (node.querySelector(
        "input:not([type='hidden']), select, textarea",
      ) as HTMLElement | null)
    : null;
}

function renderGenerateButton(label: string, readonly: unknown) {
  return E(
    'button',
    {
      class: 'btn cbi-button cbi-button-neutral fkp-generate',
      type: 'button',
      title: label,
      'aria-label': label,
      disabled: readonly ? '' : null,
    },
    renderRotateCcwIcon24(),
  );
}

// A field no loader fills stays empty until its button is pressed, and the validator asks for it.
export function addGenerateButton(
  optionRef: CBIOption,
  generate: (sectionId: string, current?: unknown) => string | null | undefined,
  title?: string,
) {
  const renderWidget = optionRef.renderWidget;

  optionRef.renderWidget = function (
    sectionId: string,
    optionIndex: string,
    cfgvalue: unknown,
  ) {
    const node = renderWidget.call(
      this,
      sectionId,
      optionIndex,
      cfgvalue,
    ) as HTMLElement;
    const label = title || _('Generate');
    const readonly = this.readonly != null ? this.readonly : this.map.readonly;
    const button = renderGenerateButton(label, readonly);

    button.addEventListener('click', (ev) => {
      ev.preventDefault();
      ev.stopPropagation();

      if (readonly) {
        return;
      }

      const element = widgetElement(node);
      const next = generate(sectionId, element ? element.getValue() : null);

      if (next == null) {
        return;
      }
      if (element) {
        element.setValue(next);
        // Validated like a typed value, so the invalid mark clears.
        if (typeof element.triggerValidation === 'function') {
          element.triggerValidation();
        }
      }
      controlOf(node)?.dispatchEvent(new Event('change', { bubbles: true }));
    });

    return E('div', { class: 'fkp-generate-row' }, [node, button]);
  };
}

export function randomHex(byteLength: number) {
  return Array.from(window.crypto.getRandomValues(new Uint8Array(byteLength)))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}
