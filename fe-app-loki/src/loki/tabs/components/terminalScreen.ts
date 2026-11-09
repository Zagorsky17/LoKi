// The part of a VT100 that install.sh and the tty driver's echo use: text, CR, LF, BS, TAB,
// SGR colors and erase in line. Other control sequences are read and dropped.

export interface TerminalStyle {
  fg: number | null;
  bg: number | null;
  bold: boolean;
  dim: boolean;
  italic: boolean;
  underline: boolean;
  inverse: boolean;
}

export interface TerminalCell {
  ch: string;
  style: TerminalStyle;
}

export const DEFAULT_STYLE: TerminalStyle = Object.freeze({
  fg: null,
  bg: null,
  bold: false,
  dim: false,
  italic: false,
  underline: false,
  inverse: false,
});

const TAB_WIDTH = 8;
const ESC = '\u001b';
const BEL = '\u0007';

type ParserState = 'text' | 'escape' | 'csi' | 'osc' | 'osc-escape';

function sgrColor(
  params: number[],
  index: number,
): { color: number | null; used: number } {
  // 38;5;n: only the 16 colors of the palette keep their meaning; the rest of 256 shows plain
  if (params[index + 1] === 5) {
    const value = params[index + 2];
    return {
      color: value !== undefined && value < 16 ? value : null,
      used: 2,
    };
  }
  if (params[index + 1] === 2) {
    return { color: null, used: 4 };
  }
  return { color: null, used: 0 };
}

export class TerminalScreen {
  lines: TerminalCell[][] = [[]];
  row = 0;
  col = 0;
  // the first line changed since the view last drew
  dirtyFrom = 0;

  private style: TerminalStyle = DEFAULT_STYLE;
  private state: ParserState = 'text';
  private params = '';

  write(data: string): void {
    for (const ch of data) {
      this.feed(ch);
    }
  }

  reset(): void {
    this.lines = [[]];
    this.row = 0;
    this.col = 0;
    this.dirtyFrom = 0;
    this.style = DEFAULT_STYLE;
    this.state = 'text';
    this.params = '';
  }

  text(): string {
    return this.lines
      .map((line) =>
        line
          .map((cell) => cell.ch)
          .join('')
          .replace(/\s+$/, ''),
      )
      .join('\n')
      .replace(/\n+$/, '');
  }

  private touch(row: number) {
    if (row < this.dirtyFrom) {
      this.dirtyFrom = row;
    }
  }

  private feed(ch: string) {
    switch (this.state) {
      case 'escape':
        this.escape(ch);
        return;
      case 'csi':
        this.csi(ch);
        return;
      case 'osc':
        if (ch === BEL) {
          this.state = 'text';
        } else if (ch === ESC) {
          this.state = 'osc-escape';
        }
        return;
      case 'osc-escape':
        this.state = ch === '\\' ? 'text' : 'osc';
        return;
      default:
        this.plain(ch);
    }
  }

  private plain(ch: string) {
    switch (ch) {
      case ESC:
        this.state = 'escape';
        return;
      case '\r':
        this.col = 0;
        return;
      case '\n':
        this.lineFeed();
        return;
      case '\b':
        if (this.col > 0) {
          this.col -= 1;
        }
        return;
      case '\t':
        this.tab();
        return;
    }
    if (ch < ' ' || ch === '\u007f') {
      return;
    }
    this.put(ch);
  }

  private escape(ch: string) {
    if (ch === '[') {
      this.state = 'csi';
      this.params = '';
      return;
    }
    // intermediate bytes, as in ESC ( B, come before the byte that ends the sequence
    if (ch >= ' ' && ch <= '/') {
      return;
    }
    this.state = ch === ']' ? 'osc' : 'text';
  }

  private csi(ch: string) {
    if (/[0-9;?<=>]/.test(ch)) {
      this.params += ch;
      return;
    }
    this.state = 'text';
    if (this.params.startsWith('?') || !/[@-~]/.test(ch)) {
      return;
    }
    const params = this.params
      .split(';')
      .map((part) => (part === '' ? NaN : Number(part)));
    const first = Number.isNaN(params[0]) ? 0 : params[0];

    switch (ch) {
      case 'm':
        this.sgr(params.map((value) => (Number.isNaN(value) ? 0 : value)));
        return;
      case 'K':
        this.eraseInLine(first);
        return;
      case 'C':
        this.moveTo(this.col + Math.max(first, 1));
        return;
      case 'D':
        this.moveTo(this.col - Math.max(first, 1));
        return;
      case 'G':
        this.moveTo(Math.max(first, 1) - 1);
        return;
      case 'J':
        if (first === 2 || first === 3) {
          this.reset();
        }
        return;
    }
  }

  private sgr(params: number[]) {
    let style: TerminalStyle = { ...this.style };
    for (let i = 0; i < params.length; i++) {
      const value = params[i];
      if (value === 0) {
        style = { ...DEFAULT_STYLE };
      } else if (value === 1) {
        style.bold = true;
      } else if (value === 2) {
        style.dim = true;
      } else if (value === 3) {
        style.italic = true;
      } else if (value === 4) {
        style.underline = true;
      } else if (value === 7) {
        style.inverse = true;
      } else if (value === 22) {
        style.bold = false;
        style.dim = false;
      } else if (value === 23) {
        style.italic = false;
      } else if (value === 24) {
        style.underline = false;
      } else if (value === 27) {
        style.inverse = false;
      } else if (value >= 30 && value <= 37) {
        style.fg = value - 30;
      } else if (value >= 90 && value <= 97) {
        style.fg = value - 90 + 8;
      } else if (value === 39) {
        style.fg = null;
      } else if (value >= 40 && value <= 47) {
        style.bg = value - 40;
      } else if (value >= 100 && value <= 107) {
        style.bg = value - 100 + 8;
      } else if (value === 49) {
        style.bg = null;
      } else if (value === 38 || value === 48) {
        const { color, used } = sgrColor(params, i);
        if (value === 38) {
          style.fg = color;
        } else {
          style.bg = color;
        }
        i += used;
      }
    }
    this.style = Object.freeze(style);
  }

  private line(): TerminalCell[] {
    return this.lines[this.row];
  }

  private put(ch: string) {
    const line = this.line();
    while (line.length < this.col) {
      line.push({ ch: ' ', style: DEFAULT_STYLE });
    }
    line[this.col] = { ch, style: this.style };
    this.col += 1;
    this.touch(this.row);
  }

  private lineFeed() {
    this.row += 1;
    if (this.row >= this.lines.length) {
      this.lines.push([]);
    }
    this.touch(this.row);
  }

  private tab() {
    this.moveTo((Math.floor(this.col / TAB_WIDTH) + 1) * TAB_WIDTH);
  }

  private moveTo(col: number) {
    this.col = Math.max(0, col);
  }

  private eraseInLine(mode: number) {
    const line = this.line();
    if (mode === 0) {
      line.length = Math.min(line.length, this.col);
    } else if (mode === 1) {
      for (let i = 0; i <= this.col && i < line.length; i++) {
        line[i] = { ch: ' ', style: DEFAULT_STYLE };
      }
    } else if (mode === 2) {
      line.length = 0;
    }
    this.touch(this.row);
  }
}
