import { addAnnotationIssue, finalizeAnnotations } from './annotations';
import type { Annotation, AnnotationMap } from './annotations';
import { escapeHtml } from '../../helpers/escapeHtml';
import { message } from '../../validators/messages';
import { validateSavedSize } from '../../validators/validateSavedSize';

const ANNOTATED_TEXTAREA_STYLE_ID = 'fkp-annotated-textarea-styles';

function ensureAnnotatedTextareaStyles() {
  if (
    typeof document === 'undefined' ||
    !document.head ||
    document.getElementById(ANNOTATED_TEXTAREA_STYLE_ID)
  ) {
    return;
  }

  document.head.insertAdjacentHTML(
    'beforeend',
    `<style id="${ANNOTATED_TEXTAREA_STYLE_ID}">
      .fkp-annotated-textarea {
        position: relative;
      }

      .fkp-annotated-textarea > textarea {
        position: relative;
        z-index: 1;
        background: transparent !important;
      }

      .fkp-annotated-textarea__overlay {
        position: absolute;
        inset: 0;
        z-index: 0;
        pointer-events: none;
        overflow: hidden;
        box-sizing: border-box;
        color: transparent;
        white-space: pre-wrap;
        word-break: break-word;
        overflow-wrap: break-word;
      }

      .fkp-annotated-textarea__invalid {
        color: transparent;
        text-decoration-line: underline;
        text-decoration-style: wavy;
        text-decoration-color: var(--error-color-medium, #d44);
        text-decoration-thickness: 1.5px;
        text-underline-offset: 2px;
        text-decoration-skip-ink: none;
      }
    </style>`,
  );
}

function applyTextareaInputAttributes(textarea: HTMLTextAreaElement) {
  textarea.setAttribute('spellcheck', 'false');
  textarea.setAttribute('autocomplete', 'off');
  textarea.setAttribute('autocorrect', 'off');
  textarea.setAttribute('autocapitalize', 'off');
  textarea.setAttribute('data-gramm', 'false');
  textarea.setAttribute('data-gramm_editor', 'false');
  textarea.setAttribute('data-enable-grammarly', 'false');
  textarea.style.resize = 'vertical';
  textarea.style.maxWidth = '100%';

  const getRowsMinHeight = () => {
    const rows = Number.parseInt(textarea.getAttribute('rows') || '0', 10);
    if (!rows || typeof window === 'undefined') {
      return 0;
    }

    const style = window.getComputedStyle(textarea);
    const fontSize = Number.parseFloat(style.fontSize) || 16;
    const lineHeight =
      Number.parseFloat(style.lineHeight) || Math.ceil(fontSize * 1.2);
    const verticalPadding =
      (Number.parseFloat(style.paddingTop) || 0) +
      (Number.parseFloat(style.paddingBottom) || 0);
    const verticalBorder =
      (Number.parseFloat(style.borderTopWidth) || 0) +
      (Number.parseFloat(style.borderBottomWidth) || 0);

    return Math.ceil(rows * lineHeight + verticalPadding + verticalBorder);
  };

  // The least height is what its rows give it, measured before a drag sets one; estimated until then.
  const applyMinHeight = () => {
    if (textarea.hasAttribute('data-fkp-default-min-height')) {
      return true;
    }

    textarea.style.minHeight = '';
    const rowsHeight = textarea.style.height ? 0 : textarea.offsetHeight;
    if (rowsHeight > 0) {
      textarea.setAttribute('data-fkp-default-min-height', `${rowsHeight}`);
      textarea.style.minHeight = `${rowsHeight}px`;
      return true;
    }

    const estimate = getRowsMinHeight();
    if (estimate > 0) {
      textarea.style.minHeight = `${estimate}px`;
    }
    return false;
  };

  if (
    !applyMinHeight() &&
    typeof window !== 'undefined' &&
    typeof window.requestAnimationFrame === 'function'
  ) {
    window.requestAnimationFrame(() => {
      if (!applyMinHeight()) {
        window.setTimeout(applyMinHeight, 0);
      }
    });
  }

  textarea.addEventListener('focus', applyMinHeight);
  textarea.addEventListener('pointerdown', applyMinHeight);
}

function syncAnnotatedTextareaOverlay(
  textarea: HTMLTextAreaElement,
  wrapper: HTMLElement,
  overlay: HTMLElement,
) {
  if (
    typeof window === 'undefined' ||
    !textarea ||
    !wrapper ||
    !overlay ||
    typeof window.getComputedStyle !== 'function'
  ) {
    return;
  }

  const style = window.getComputedStyle(textarea);

  wrapper.style.backgroundColor = style.backgroundColor;
  wrapper.style.borderRadius = style.borderRadius;

  overlay.style.font = style.font;
  overlay.style.lineHeight = style.lineHeight;
  overlay.style.letterSpacing = style.letterSpacing;
  overlay.style.paddingTop = style.paddingTop;
  overlay.style.paddingRight = style.paddingRight;
  overlay.style.paddingBottom = style.paddingBottom;
  overlay.style.paddingLeft = style.paddingLeft;
  overlay.style.borderTopWidth = style.borderTopWidth;
  overlay.style.borderRightWidth = style.borderRightWidth;
  overlay.style.borderBottomWidth = style.borderBottomWidth;
  overlay.style.borderLeftWidth = style.borderLeftWidth;
  overlay.style.borderStyle = 'solid';
  overlay.style.borderColor = 'transparent';
  overlay.style.textAlign = style.textAlign;
  overlay.style.direction = style.direction;
  overlay.style.tabSize = style.tabSize;
  overlay.style.textIndent = style.textIndent;
  overlay.style.textTransform = style.textTransform;
  overlay.style.boxSizing = style.boxSizing;
  overlay.style.scrollPaddingTop = style.scrollPaddingTop;

  overlay.scrollTop = textarea.scrollTop;
  overlay.scrollLeft = textarea.scrollLeft;
}

function renderAnnotatedTextareaOverlay(
  value: unknown,
  annotations: Annotation[] | undefined,
): string {
  const text = value ? `${value}` : '';
  const normalizedAnnotations = Array.isArray(annotations) ? annotations : [];

  if (!text.length) {
    return '&#8203;';
  }

  if (!normalizedAnnotations.length) {
    return `${escapeHtml(text)}${text.endsWith('\n') ? '\n ' : ''}`;
  }

  let cursor = 0;
  let html = '';

  normalizedAnnotations.forEach((annotation) => {
    if (
      annotation.start < cursor ||
      annotation.start >= annotation.end ||
      annotation.start < 0
    ) {
      return;
    }

    html += escapeHtml(text.slice(cursor, annotation.start));
    html += `<span class="fkp-annotated-textarea__invalid">${escapeHtml(
      text.slice(annotation.start, annotation.end),
    )}</span>`;
    cursor = annotation.end;
  });

  html += escapeHtml(text.slice(cursor));

  if (text.endsWith('\n')) {
    html += '\n ';
  }

  return html;
}

function attachAnnotatedTextarea(
  textarea: HTMLTextAreaElement,
  analyzer: TextAnalyzer,
) {
  if (!textarea || typeof analyzer !== 'function') {
    return;
  }

  ensureAnnotatedTextareaStyles();

  if (textarea.__lokiAnnotatedTextareaController) {
    textarea.__lokiAnnotatedTextareaController.analyzer = analyzer;
    textarea.__lokiAnnotatedTextareaController.update();
    return;
  }

  const wrapper = textarea.parentNode as HTMLElement | null;
  if (!wrapper) {
    return;
  }

  wrapper.classList.add('fkp-annotated-textarea');

  const overlay = document.createElement('div');
  overlay.className = 'fkp-annotated-textarea__overlay';
  overlay.setAttribute('aria-hidden', 'true');
  wrapper.insertBefore(overlay, textarea.nextSibling);

  const controller: AnnotatedTextareaController = {
    analyzer,
    textarea,
    wrapper,
    overlay,
    update() {
      const analysis = this.analyzer(this.textarea.value);
      this.overlay.innerHTML = renderAnnotatedTextareaOverlay(
        this.textarea.value,
        analysis.annotations,
      );
      syncAnnotatedTextareaOverlay(this.textarea, this.wrapper, this.overlay);
    },
  };

  textarea.__lokiAnnotatedTextareaController = controller;

  const updateAnnotatedTextarea = () => controller.update();
  textarea.addEventListener('input', updateAnnotatedTextarea);
  textarea.addEventListener('change', updateAnnotatedTextarea);
  textarea.addEventListener('scroll', updateAnnotatedTextarea, {
    passive: true,
  });
  textarea.addEventListener('keyup', updateAnnotatedTextarea);

  if (typeof ResizeObserver === 'function') {
    const resizeObserver = new ResizeObserver(() => controller.update());
    resizeObserver.observe(textarea);
    controller.resizeObserver = resizeObserver;
  }

  controller.update();
}

export function parseCommentAwareListTokens(value: unknown): TextToken[] {
  const text = value ? `${value}` : '';
  const tokens: TextToken[] = [];
  const lines = text.split(/\r\n|\r|\n/);
  const newlines = text.match(/\r\n|\r|\n/g) || [];
  let offset = 0;

  lines.forEach((line, index: number) => {
    const hashIndex = line.indexOf('#');
    const slashIndex = line.indexOf('//');
    let commentIndex = -1;

    if (hashIndex >= 0 && slashIndex >= 0) {
      commentIndex = Math.min(hashIndex, slashIndex);
    } else if (hashIndex >= 0) {
      commentIndex = hashIndex;
    } else if (slashIndex >= 0) {
      commentIndex = slashIndex;
    }

    const source = commentIndex >= 0 ? line.slice(0, commentIndex) : line;
    const matcher = /[^,\s]+/g;
    let match;

    while ((match = matcher.exec(source)) !== null) {
      tokens.push({
        value: match[0],
        start: offset + match.index,
        end: offset + match.index + match[0].length,
      });
    }

    offset += line.length + (newlines[index] ? newlines[index].length : 0);
  });

  return tokens;
}

export function analyzeTextListValue(
  value: unknown,
  validateItem: TextItemValidator | null,
  options: TextListAnalysisOptions = {},
): TextAnalysis {
  const tokens = parseCommentAwareListTokens(value ? `${value}` : '');
  const duplicateMessage = options.duplicateMessage || message.duplicate();
  const annotationMap: AnnotationMap = new Map();
  const errors: string[] = [];
  const seen = new Set<string>();

  tokens.forEach((token) => {
    if (typeof validateItem === 'function') {
      const validation = validateItem(token.value);
      if (validation !== true) {
        errors.push(`${token.value}: ${validation}`);
        addAnnotationIssue(annotationMap, token, validation);
      }
    }

    const normalized = options.normalizeDuplicateValue
      ? options.normalizeDuplicateValue(token.value)
      : token.value;

    if (!normalized) {
      return;
    }

    if (seen.has(normalized)) {
      errors.push(`${token.value}: ${duplicateMessage}`);
      addAnnotationIssue(annotationMap, token, duplicateMessage);
      return;
    }

    seen.add(normalized);
  });

  if (!errors.length) {
    return { valid: true, message: '', annotations: [] };
  }

  return {
    valid: false,
    message: errors.join('\n'),
    annotations: finalizeAnnotations(annotationMap),
  };
}

export function configureTextareaOption(
  option: CBIOption,
  analyzer?: TextAnalyzer | null,
) {
  const originalRenderWidget = option.renderWidget;
  // Taken at render, where LuCI binds the check to the widget, so a check set after this call counts.
  let validate = option.validate;
  const validateWithSize = function (
    this: CBIOption,
    section_id: string,
    value: string,
  ) {
    const size = validateSavedSize(value);
    if (size !== true) return size;
    return validate ? validate.call(this, section_id, value) : true;
  };

  option.renderWidget = function (
    section_id: string,
    option_index: string,
    cfgvalue: unknown,
  ) {
    if (this.validate !== validateWithSize) {
      validate = this.validate;
      this.validate = validateWithSize;
    }
    const node = originalRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    ) as HTMLElement;
    const textarea =
      node && typeof node.querySelector === 'function'
        ? node.querySelector('textarea')
        : (node as HTMLTextAreaElement);

    if (textarea) {
      applyTextareaInputAttributes(textarea);
      textarea.addEventListener('input', () => {
        node.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
      });
      if (typeof analyzer === 'function') {
        attachAnnotatedTextarea(textarea, analyzer);
      }
    }

    return node;
  };
}
