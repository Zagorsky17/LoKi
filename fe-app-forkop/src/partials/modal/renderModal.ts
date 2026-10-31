// Modified for LoKi on 2026-11-01: confirm raw access and prevent exports during privacy transitions.
import { renderButton } from '../button/renderButton';
import { copyToClipboard } from '../../helpers/copyToClipboard';
import { downloadAsTxt } from '../../helpers/downloadAsTxt';
import { showToast } from '../../helpers/showToast';
import { E } from '../../helpers/element';

interface RenderModalOptions {
  // Asked again on every flip of the masking toggle: the router masks, so the
  // page never holds an unmasked copy nobody asked to see.
  getText?: (context: { maskValues: boolean }) => Promise<string>;
  showMaskValuesToggle?: boolean;
}

// The last flip of the masking toggle wins: a slow answer to an earlier one never replaces it, and
// a flip whose text could not be read is undone.
export function renderModal(
  text: string,
  name: string,
  options?: RenderModalOptions,
) {
  let currentText = text ?? '';
  let latestRequest = 0;
  let loading = false;
  let currentMasked = true;

  const codeEl = E('code', {}, currentText) as HTMLElement;
  const contentEl = E(
    'pre',
    { class: 'fkp-partial-modal__content' },
    codeEl,
  ) as HTMLElement;

  const downloadButton = renderButton({
    classNames: ['cbi-button-apply'],
    text: _('Download'),
    onClick: () => {
      if (!loading) downloadAsTxt(currentText, name);
    },
  }) as HTMLButtonElement;
  const copyButton = renderButton({
    classNames: ['cbi-button-apply'],
    text: _('Copy'),
    onClick: () => {
      if (!loading) copyToClipboard(`\`\`\`${name}\n${currentText}\n\`\`\``);
    },
  }) as HTMLButtonElement;
  const footerChildren: HTMLElement[] = [
    downloadButton,
    copyButton,
    renderButton({
      classNames: ['cbi-button-remove'],
      text: _('Close'),
      onClick: () => ui.hideModal(),
    }),
  ];

  const getText = options?.getText;
  if (getText && options?.showMaskValuesToggle) {
    const maskValuesInput = document.createElement('input');
    maskValuesInput.type = 'checkbox';
    maskValuesInput.className = 'cbi-input-checkbox';
    maskValuesInput.checked = true;
    maskValuesInput.addEventListener('change', async () => {
      const maskValues = maskValuesInput.checked;
      if (
        !maskValues &&
        !window.confirm(
          _(
            'Show an unmasked report? It contains keys and passwords. Do not share it.',
          ),
        )
      ) {
        maskValuesInput.checked = currentMasked;
        return;
      }
      const request = ++latestRequest;
      loading = true;
      downloadButton.disabled = copyButton.disabled = true;

      try {
        const nextText = await getText({ maskValues });
        if (request === latestRequest) {
          currentText = nextText ?? '';
          currentMasked = maskValues;
          maskValuesInput.checked = currentMasked;
          codeEl.textContent = currentText;
        }
      } catch {
        console.warn('[renderModal] failed to load the text');
        if (request === latestRequest) {
          maskValuesInput.checked = currentMasked;
          showToast(_('Failed to load diagnostics'), 'error');
        }
      } finally {
        if (request === latestRequest) {
          loading = false;
          downloadButton.disabled = copyButton.disabled = false;
        }
      }
    });

    footerChildren.unshift(
      E('label', { class: 'fkp-partial-modal__checkbox' }, [
        maskValuesInput,
        E(
          'span',
          { class: 'fkp-partial-modal__checkbox-text' },
          _('Hide values'),
        ),
      ]) as HTMLElement,
    );
  }

  return E('div', { class: 'fkp-partial-modal__body' }, [
    E('div', {}, [
      contentEl,
      E('div', { class: 'fkp-partial-modal__footer' }, footerChildren),
    ]),
  ]) as HTMLElement;
}
