import { describe, expect, it } from 'vitest';
import { isInterrupt, keyInput, lineRuns, typedInput } from '../terminal';
import { TerminalScreen } from '../terminalScreen';

function line(data: string) {
  const screen = new TerminalScreen();
  screen.write(data);
  return screen.lines[0];
}

const key = (
  name: string,
  modifiers: Partial<Record<'ctrlKey' | 'altKey' | 'metaKey', boolean>> = {},
) => ({
  key: name,
  ctrlKey: false,
  altKey: false,
  metaKey: false,
  ...modifiers,
});

describe('terminal lines', () => {
  it('draws a line as runs of one style', () => {
    expect(lineRuns(line('\u001b[1;36m[*]\u001b[0m step'), null)).toEqual([
      { className: 'fkp_terminal__fg-6 fkp_terminal__bold', text: '[*]' },
      { className: '', text: ' step' },
    ]);
    expect(lineRuns([], null)).toEqual([]);
  });

  it('shows the cursor on its own cell, past the end as a blank', () => {
    expect(lineRuns(line('ab'), 1)).toEqual([
      { className: '', text: 'a' },
      { className: 'fkp_terminal__cursor', text: 'b' },
    ]);
    expect(lineRuns(line('[2]: '), 5)).toEqual([
      { className: '', text: '[2]: ' },
      { className: 'fkp_terminal__cursor', text: ' ' },
    ]);
    expect(lineRuns(line('abc'), 0)).toEqual([
      { className: 'fkp_terminal__cursor', text: 'a' },
      { className: '', text: 'bc' },
    ]);
  });

  it('swaps the colors of inverse text', () => {
    expect(lineRuns(line('\u001b[7;31mx'), null)[0].className).toBe(
      'fkp_terminal__inverse fkp_terminal__bg-1',
    );
  });
});

describe('terminal keys', () => {
  it('sends Enter, Backspace and Tab as a terminal does', () => {
    expect(keyInput(key('Enter'))).toBe('\r');
    expect(keyInput(key('Backspace'))).toBe('\u007f');
    expect(keyInput(key('Tab'))).toBe('\t');
  });

  it('sends Ctrl+D and Ctrl+U, and leaves other shortcuts to the browser', () => {
    expect(keyInput(key('d', { ctrlKey: true }))).toBe('\u0004');
    expect(keyInput(key('u', { ctrlKey: true }))).toBe('\u0015');
    expect(keyInput(key('s', { ctrlKey: true }))).toBeUndefined();
    expect(keyInput(key('r', { ctrlKey: true }))).toBeUndefined();
    expect(keyInput(key('Enter', { altKey: true }))).toBeUndefined();
    expect(keyInput(key('c', { metaKey: true }))).toBeUndefined();
  });

  it('takes Ctrl+C for a stop, never for a character', () => {
    expect(isInterrupt(key('c', { ctrlKey: true }))).toBe(true);
    expect(isInterrupt(key('C', { ctrlKey: true }))).toBe(true);
    expect(keyInput(key('c', { ctrlKey: true }))).toBeUndefined();
    expect(isInterrupt(key('c', { metaKey: true }))).toBe(false);
    expect(isInterrupt(key('c', { ctrlKey: true, altKey: true }))).toBe(false);
    expect(isInterrupt(key('c'))).toBe(false);
  });

  it('leaves letters to the input event, which carries layouts and phones', () => {
    expect(keyInput(key('2'))).toBeUndefined();
    expect(keyInput(key('д'))).toBeUndefined();
    expect(keyInput(key('ArrowUp'))).toBeUndefined();
  });

  it('turns pasted line breaks into Enter', () => {
    expect(typedInput('y\n')).toBe('y\r');
    expect(typedInput('a\r\nb')).toBe('a\rb');
    expect(typedInput('да')).toBe('да');
  });
});
