// The core reports a non-Latin label in its Punycode form (RFC 3492), which the browser cannot decode.

const BASE = 36;
const T_MIN = 1;
const T_MAX = 26;
const SKEW = 38;
const DAMP = 700;
const INITIAL_BIAS = 72;
const INITIAL_N = 128;
const MAX_CODE_POINT = 0x10ffff;

function adapt(delta: number, points: number, first: boolean): number {
  let scaled = first ? Math.floor(delta / DAMP) : Math.floor(delta / 2);
  scaled += Math.floor(scaled / points);

  let k = 0;
  while (scaled > ((BASE - T_MIN) * T_MAX) / 2) {
    scaled = Math.floor(scaled / (BASE - T_MIN));
    k += BASE;
  }

  return k + Math.floor(((BASE - T_MIN + 1) * scaled) / (scaled + SKEW));
}

function digitValue(code: number): number {
  if (code >= 0x30 && code <= 0x39) {
    return code - 0x30 + 26;
  }
  if (code >= 0x61 && code <= 0x7a) {
    return code - 0x61;
  }
  return BASE;
}

function decodeLabel(encoded: string): string | null {
  const delimiter = encoded.lastIndexOf('-');
  const output: number[] = [];

  for (let index = 0; index < Math.max(delimiter, 0); index += 1) {
    output.push(encoded.charCodeAt(index));
  }

  let n = INITIAL_N;
  let i = 0;
  let bias = INITIAL_BIAS;
  let index = delimiter > 0 ? delimiter + 1 : 0;

  while (index < encoded.length) {
    const previous = i;
    let weight = 1;

    for (let k = BASE; ; k += BASE) {
      if (index >= encoded.length) {
        return null;
      }

      const digit = digitValue(encoded.charCodeAt(index));
      index += 1;
      if (digit >= BASE) {
        return null;
      }

      i += digit * weight;
      const threshold =
        k <= bias ? T_MIN : k >= bias + T_MAX ? T_MAX : k - bias;
      if (digit < threshold) {
        break;
      }
      weight *= BASE - threshold;
    }

    bias = adapt(i - previous, output.length + 1, previous === 0);
    n += Math.floor(i / (output.length + 1));
    i %= output.length + 1;

    if (n > MAX_CODE_POINT || (n >= 0xd800 && n <= 0xdfff)) {
      return null;
    }

    output.splice(i, 0, n);
    i += 1;
  }

  return output.length ? String.fromCodePoint(...output) : null;
}

// A label mixing Latin with another script spells a look-alike (a Cyrillic "а" in "аpple"), so it
// keeps its ASCII form, as browsers do.
function mixesLatin(label: string): boolean {
  return (
    /\p{Script=Latin}/u.test(label) && /(?!\p{Script=Latin})\p{L}/u.test(label)
  );
}

export function domainToUnicode(domain: string): string {
  return domain
    .split('.')
    .map((label) => {
      if (!/^xn--/i.test(label)) {
        return label;
      }

      const decoded = decodeLabel(label.slice(4).toLowerCase());
      return decoded && !mixesLatin(decoded) ? decoded : label;
    })
    .join('.');
}
