import { describe, expect, it } from 'vitest';
import { TerminalScreen } from '../terminalScreen';

function screenAfter(...writes: string[]) {
  const screen = new TerminalScreen();
  for (const data of writes) {
    screen.write(data);
  }
  return screen;
}

function styleAt(screen: TerminalScreen, row: number, col: number) {
  return screen.lines[row][col].style;
}

describe('terminal screen', () => {
  it('keeps install.sh lines as the tty driver ends them', () => {
    const screen = screenAfter(
      'Установщик LoKi\r\n\r\n[*] Поиск последней версии\r\n',
    );
    expect(screen.text()).toBe('Установщик LoKi\n\n[*] Поиск последней версии');
    expect([screen.row, screen.col]).toEqual([3, 0]);
  });

  it('colors what SGR names and resets it, as install.sh marks its lines', () => {
    const screen = screenAfter(
      '\u001b[1;36m[*]\u001b[0m step \u001b[1;32m[+]\u001b[0m \u001b[1;31m[x]\u001b[0m',
    );
    expect(screen.text()).toBe('[*] step [+] [x]');
    expect(styleAt(screen, 0, 0)).toMatchObject({ fg: 6, bold: true });
    expect(styleAt(screen, 0, 3)).toMatchObject({ fg: null, bold: false });
    expect(styleAt(screen, 0, 9)).toMatchObject({ fg: 2, bold: true });
    expect(styleAt(screen, 0, 13)).toMatchObject({ fg: 1, bold: true });
  });

  it('reads the bright, background and 256-color forms', () => {
    const screen = screenAfter(
      '\u001b[93;44ma\u001b[39;49mb\u001b[38;5;3mc\u001b[38;5;200md\u001b[38;2;1;2;3me\u001b[7;4;3;2mf\u001b[22;23;24;27mg',
    );
    expect(styleAt(screen, 0, 0)).toMatchObject({ fg: 11, bg: 4 });
    expect(styleAt(screen, 0, 1)).toMatchObject({ fg: null, bg: null });
    expect(styleAt(screen, 0, 2).fg).toBe(3);
    expect(styleAt(screen, 0, 3).fg).toBeNull();
    expect(styleAt(screen, 0, 4).fg).toBeNull();
    expect(styleAt(screen, 0, 5)).toMatchObject({
      inverse: true,
      underline: true,
      italic: true,
      dim: true,
    });
    expect(styleAt(screen, 0, 6)).toMatchObject({
      inverse: false,
      underline: false,
      italic: false,
      dim: false,
      bold: false,
    });
  });

  it('echoes a typed answer and erases it the way the tty driver does', () => {
    const screen = screenAfter(
      'Какую сборку установить? [2]: ',
      '3',
      '\b \b',
      '1\r\n',
    );
    expect(screen.text()).toBe('Какую сборку установить? [2]: 1');
    expect([screen.row, screen.col]).toEqual([1, 0]);
  });

  it('writes over a line from its start after a carriage return', () => {
    const screen = screenAfter('progress 10%\rprogress 100%\r\n');
    expect(screen.text()).toBe('progress 100%');
    expect(screenAfter('long line\rshort\u001b[K').text()).toBe('short');
  });

  it('erases in line, moves the cursor and tabs over blanks', () => {
    expect(screenAfter('abcdef\u001b[3D\u001b[1K').text()).toBe('    ef');
    expect(screenAfter('abcdef\r\u001b[2K').text()).toBe('');
    expect(screenAfter('ab\u001b[5Gc').text()).toBe('ab  c');
    expect(screenAfter('a\u001b[2Cb').text()).toBe('a  b');
    expect(screenAfter('a\tb').text()).toBe('a       b');
    expect(screenAfter('abc\u001b[2J').text()).toBe('');
  });

  it('drops what it does not draw: private modes, OSC, other escapes and controls', () => {
    const screen = screenAfter(
      '\u001b[?25la\u001b]0;title\u0007b\u001b]8;;x\u001b\\c\u001b(Bd\u0007\u0001e\u007f',
    );
    expect(screen.text()).toBe('abcde');
  });

  it('reads a sequence split across writes', () => {
    expect(screenAfter('\u001b[1', ';31mred', '\u001b', '[0m').text()).toBe(
      'red',
    );
    const screen = screenAfter('\u001b[1', ';31mred');
    expect(styleAt(screen, 0, 0)).toMatchObject({ fg: 1, bold: true });
  });

  it('says which lines changed since the view last drew', () => {
    const screen = screenAfter('one\r\ntwo\r\n');
    screen.dirtyFrom = screen.lines.length;
    screen.write('three');
    expect(screen.dirtyFrom).toBe(2);
    screen.dirtyFrom = screen.lines.length;
    screen.write('\b\b\b\b\bTHREE');
    expect(screen.dirtyFrom).toBe(2);
    screen.reset();
    expect([screen.dirtyFrom, screen.text()]).toEqual([0, '']);
  });
});
