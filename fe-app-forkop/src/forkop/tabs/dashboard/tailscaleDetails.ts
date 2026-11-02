import { E } from '../../../helpers/element';
import { showToast } from '../../../helpers/showToast';

function svgEl(
  tag: string,
  attrs: Record<string, string> = {},
  children: Node[] = [],
) {
  const element = document.createElementNS('http://www.w3.org/2000/svg', tag);
  Object.entries(attrs).forEach(([key, value]) => {
    if (value != null) {
      element.setAttribute(key, `${value}`);
    }
  });
  (Array.isArray(children) ? children : [children])
    .filter(Boolean)
    .forEach((child) => element.appendChild(child));
  return element;
}

type IconPath = [string, Record<string, string>];

// Lucide outlines at the size and stroke the rest of Forkop already uses.
const ICON_PATHS: Record<string, IconPath[]> = {
  copy: [
    ['rect', { x: '9', y: '9', width: '13', height: '13', rx: '2', ry: '2' }],
    ['path', { d: 'M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1' }],
  ],
  user: [
    ['path', { d: 'M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2' }],
    ['circle', { cx: '12', cy: '7', r: '4' }],
  ],
};

export function iconSvg(name: string) {
  return svgEl(
    'svg',
    {
      viewBox: '0 0 24 24',
      width: '16',
      height: '16',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      'aria-hidden': 'true',
      focusable: 'false',
    },
    ICON_PATHS[name].map(([tag, attrs]) => svgEl(tag, attrs)),
  );
}

function copyText(text: string) {
  const textarea = document.createElement('textarea');
  textarea.value = text;
  textarea.style.position = 'fixed';
  textarea.style.top = '0';
  textarea.style.left = '0';
  textarea.style.opacity = '0';
  document.body.appendChild(textarea);
  textarea.select();

  let copied = false;
  try {
    copied = document.execCommand('copy');
  } catch (error) {
    console.warn('Failed to copy the value', error);
  }

  document.body.removeChild(textarea);
  return copied;
}

const DETAILS_STYLE_ID = 'forkop-tailscale-details-styles';

export function injectDetailsStyles() {
  if (document.getElementById(DETAILS_STYLE_ID)) {
    return;
  }

  document.head.appendChild(
    E(
      'style',
      { id: DETAILS_STYLE_ID },
      [
        // The same dl/dt/dd as the URLTest and Fallback details: the theme styles the tags, not classes.
        // All three open without cbi-modal, which the theme widens to a settings form.
        '.fkp-details{box-sizing:border-box;width:min(760px,calc(100vw - 56px));max-width:100%;padding-top:10px}',
        '.fkp-details__empty{color:var(--text-color-medium,#666)}',
        // The theme lays a modal button row out space-between with an auto margin on the first button;
        // these selectors match its specificity to put a lone button on the left.
        '.modal > .button-row.fkp-details-actions{justify-content:flex-start;gap:0.5em}',
        '.modal > .button-row.fkp-details-actions > button:first-of-type{margin-right:0}',
      ].join('\n'),
    ),
  );
}

export function copyWithToast(value: string) {
  const copied = copyText(value);
  showToast(
    copied ? _('Copied') : _('Failed to copy!'),
    copied ? 'success' : 'error',
  );
}

export function renderCloseRow() {
  return E('div', { class: 'button-row fkp-details-actions' }, [
    E(
      'button',
      {
        class: 'btn cbi-button cbi-button-neutral',
        type: 'button',
        click: () => ui.hideModal(),
      },
      _('Close'),
    ),
  ]);
}
