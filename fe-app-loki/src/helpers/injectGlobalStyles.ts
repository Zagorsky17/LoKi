import { GlobalStyles } from '../styles';

const LOKI_GLOBAL_STYLES_ID = 'loki-global-styles';

export function injectGlobalStyles() {
  if (document.getElementById(LOKI_GLOBAL_STYLES_ID)) {
    return;
  }

  document.head.insertAdjacentHTML(
    'beforeend',
    `
        <style id="${LOKI_GLOBAL_STYLES_ID}">
          ${GlobalStyles}
        </style>
    `,
  );
}
