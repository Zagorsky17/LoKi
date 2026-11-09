import { TerminalCell, TerminalScreen, TerminalStyle } from './terminalScreen';

// Keystrokes typed this close together go out in one call.
const INPUT_FLUSH_MS = 30;
// Within this of the bottom the view follows new output; scrolled further up, it stays put.
const FOLLOW_SLACK_PX = 24;

export interface TerminalView {
  element: HTMLElement;
  write(data: string): void;
  reset(): void;
  setInput(enabled: boolean): void;
  focus(): void;
  text(): string;
}

export interface TerminalRun {
  className: string;
  text: string;
}

function styleClass(style: TerminalStyle): string {
  let fg = style.fg;
  let bg = style.bg;
  const classes: string[] = [];
  if (style.inverse) {
    [fg, bg] = [bg, fg];
    classes.push('fkp_terminal__inverse');
  }
  if (fg !== null) {
    classes.push(`fkp_terminal__fg-${fg}`);
  }
  if (bg !== null) {
    classes.push(`fkp_terminal__bg-${bg}`);
  }
  if (style.bold) {
    classes.push('fkp_terminal__bold');
  }
  if (style.dim) {
    classes.push('fkp_terminal__dim');
  }
  if (style.italic) {
    classes.push('fkp_terminal__italic');
  }
  if (style.underline) {
    classes.push('fkp_terminal__underline');
  }
  return classes.join(' ');
}

// A line as runs of one style; the cursor, when shown, is a cell of its own, past the end a
// blank one.
export function lineRuns(
  cells: TerminalCell[],
  cursor: number | null,
): TerminalRun[] {
  const runs: TerminalRun[] = [];
  const length =
    cursor === null ? cells.length : Math.max(cells.length, cursor + 1);
  for (let i = 0; i < length; i++) {
    const cell = cells[i];
    const className = cell ? styleClass(cell.style) : '';
    const ch = cell?.ch ?? ' ';
    if (i === cursor) {
      runs.push({
        className: `${className} fkp_terminal__cursor`.trim(),
        text: ch === ' ' ? ' ' : ch,
      });
      continue;
    }
    const last = runs[runs.length - 1];
    if (last && i - 1 !== cursor && last.className === className) {
      last.text += ch;
    } else {
      runs.push({ className, text: ch });
    }
  }
  return runs;
}

const CONTROL_KEYS: Record<string, string> = {
  d: '\u0004',
  u: '\u0015',
};

const PLAIN_KEYS: Record<string, string> = {
  Enter: '\r',
  Backspace: '\u007f',
  Tab: '\t',
};

interface KeyEvent {
  key: string;
  ctrlKey: boolean;
  altKey: boolean;
  metaKey: boolean;
}

// What a key sends to the terminal, as a terminal emulator sends it; undefined leaves the key to
// the browser, text included, which arrives as input.
export function keyInput(event: KeyEvent): string | undefined {
  if (event.altKey || event.metaKey) {
    return undefined;
  }
  return event.ctrlKey
    ? CONTROL_KEYS[event.key.toLowerCase()]
    : PLAIN_KEYS[event.key];
}

// Ctrl+C stops the run the way the stop button does, never as a SIGINT from the terminal: that
// would reach the package manager install.sh shields itself from.
export function isInterrupt(event: KeyEvent): boolean {
  return (
    event.ctrlKey &&
    !event.altKey &&
    !event.metaKey &&
    event.key.toLowerCase() === 'c'
  );
}

// Typed or pasted text, with its line breaks as the Enter key sends them.
export function typedInput(value: string): string {
  return value.replace(/\r\n|\n/g, '\r');
}

function span(run: TerminalRun): HTMLElement {
  const node = document.createElement('span');
  if (run.className) {
    node.className = run.className;
  }
  node.textContent = run.text;
  return node;
}

export function createTerminal(options: {
  label: string;
  onInput: (data: string) => void;
  onInterrupt: () => void;
}): TerminalView {
  const screen = new TerminalScreen();
  const output = document.createElement('pre');
  output.className = 'fkp_terminal__output';
  output.setAttribute('role', 'log');
  output.setAttribute('aria-label', options.label);

  // A hidden field takes the keys: it gets IME input, pasting and a phone's keyboard for free.
  const input = document.createElement('textarea');
  input.className = 'fkp_terminal__input';
  input.setAttribute('aria-label', options.label);
  input.setAttribute('autocomplete', 'off');
  input.setAttribute('autocapitalize', 'off');
  input.setAttribute('autocorrect', 'off');
  input.spellcheck = false;
  input.tabIndex = -1;

  const root = document.createElement('div');
  root.className = 'fkp_terminal';
  root.append(output, input);

  const lineNodes: HTMLElement[] = [];
  let inputEnabled = false;
  let composing = false;
  let pending = '';
  let flushTimer: ReturnType<typeof setTimeout> | null = null;
  let drawnCursorRow: number | null = null;
  // Whether the view keeps to the end; output written while it was hidden is scrolled to once
  // it has a size.
  let following = true;

  function atBottom() {
    return (
      output.scrollHeight - output.scrollTop - output.clientHeight <=
      FOLLOW_SLACK_PX
    );
  }

  function keepToEnd() {
    if (following) {
      output.scrollTop = output.scrollHeight;
    }
  }

  output.addEventListener('scroll', () => {
    if (output.clientHeight > 0) {
      following = atBottom();
    }
  });
  if (typeof ResizeObserver !== 'undefined') {
    new ResizeObserver(keepToEnd).observe(output);
  }

  // Every line but the first starts with its line break, so text copied out of the terminal
  // keeps its lines.
  function drawLine(row: number, cursor: number | null) {
    let node = lineNodes[row];
    if (!node) {
      node = document.createElement('span');
      node.className = 'fkp_terminal__line';
      lineNodes[row] = node;
      output.appendChild(node);
    }
    const parts: Node[] = row === 0 ? [] : [document.createTextNode('\n')];
    for (const run of lineRuns(screen.lines[row], cursor)) {
      parts.push(span(run));
    }
    node.replaceChildren(...parts);
  }

  function draw() {
    const cursorRow = inputEnabled ? screen.row : null;
    let from = screen.dirtyFrom;
    if (drawnCursorRow !== null && drawnCursorRow !== cursorRow) {
      from = Math.min(from, drawnCursorRow);
    }
    if (cursorRow !== null) {
      from = Math.min(from, cursorRow);
    }
    while (lineNodes.length > screen.lines.length) {
      lineNodes.pop()?.remove();
    }
    for (let row = Math.max(0, from); row < screen.lines.length; row++) {
      drawLine(row, row === cursorRow ? screen.col : null);
    }
    screen.dirtyFrom = screen.lines.length;
    drawnCursorRow = cursorRow;
    keepToEnd();
  }

  function flushInput() {
    flushTimer = null;
    const data = pending;
    pending = '';
    if (data) {
      options.onInput(data);
    }
  }

  function send(data: string) {
    if (!inputEnabled || !data) {
      return;
    }
    pending += data;
    flushTimer ??= setTimeout(flushInput, INPUT_FLUSH_MS);
  }

  function takeTyped() {
    const value = input.value;
    input.value = '';
    send(typedInput(value));
  }

  input.addEventListener('keydown', (event) => {
    if (!inputEnabled || event.isComposing) {
      return;
    }
    // Ctrl+C copies what is selected, as in a terminal emulator; with nothing selected it interrupts
    if (isInterrupt(event)) {
      if (!window.getSelection()?.toString()) {
        event.preventDefault();
        options.onInterrupt();
      }
      return;
    }
    const data = keyInput(event);
    if (data !== undefined) {
      event.preventDefault();
      send(data);
    }
  });
  input.addEventListener('compositionstart', () => {
    composing = true;
  });
  input.addEventListener('compositionend', () => {
    composing = false;
    takeTyped();
  });
  input.addEventListener('input', () => {
    if (!composing) {
      takeTyped();
    }
  });
  input.addEventListener('focus', () =>
    root.classList.add('fkp_terminal--focused'),
  );
  input.addEventListener('blur', () =>
    root.classList.remove('fkp_terminal--focused'),
  );

  // A click types; a drag selects text to copy and leaves the selection alone.
  root.addEventListener('click', () => {
    if (inputEnabled && !window.getSelection()?.toString()) {
      input.focus({ preventScroll: true });
    }
  });

  return {
    element: root,
    write(data: string) {
      screen.write(data);
      draw();
    },
    reset() {
      screen.reset();
      lineNodes.splice(0).forEach((node) => node.remove());
      drawnCursorRow = null;
      following = true;
      draw();
    },
    setInput(enabled: boolean) {
      if (enabled === inputEnabled) {
        return;
      }
      inputEnabled = enabled;
      root.classList.toggle('fkp_terminal--input', enabled);
      if (!enabled) {
        pending = '';
        input.blur();
      }
      draw();
    },
    focus() {
      if (inputEnabled) {
        input.focus({ preventScroll: true });
      }
    },
    text() {
      return screen.text();
    },
  };
}
