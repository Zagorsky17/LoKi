import { message } from './messages';
import { asciiHostname, validAsciiDomain } from './validateDomain';
import { isIPv4, isIPv6 } from './validateIp';

interface TextAnnotation {
  start: number;
  end: number;
  message: string;
}

interface StaticHostsAnalysis {
  valid: boolean;
  message: string;
  annotations: TextAnnotation[];
}

interface Field {
  value: string;
  start: number;
  end: number;
}

function lineFields(line: string, offset: number): Field[] {
  const commentIndex = line.search(/\/\/|#/);
  const body = commentIndex >= 0 ? line.slice(0, commentIndex) : line;
  const fields: Field[] = [];
  const pattern = /[^\s]+/g;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(body)) !== null) {
    fields.push({
      value: match[0],
      start: offset + match.index,
      end: offset + match.index + match[0].length,
    });
  }

  return fields;
}

export function analyzeStaticHosts(text: string): StaticHostsAnalysis {
  const value = `${text || ''}`;
  const annotations: TextAnnotation[] = [];
  const errors: string[] = [];
  let offset = 0;

  const reject = (field: Field, reason: string) => {
    annotations.push({ start: field.start, end: field.end, message: reason });
    errors.push(`${field.value}: ${reason}`);
  };

  for (const line of value.split('\n')) {
    const fields = lineFields(line, offset);
    offset += line.length + 1;

    if (!fields.length) {
      continue;
    }

    const [address, ...domains] = fields;

    if (!isIPv4(address.value) && !isIPv6(address.value)) {
      reject(address, message.invalidIp());
    }

    if (!domains.length) {
      reject(address, _('No domain'));
      continue;
    }

    for (const domain of domains) {
      const ascii = asciiHostname(domain.value.toLowerCase());

      if (!ascii || !validAsciiDomain(ascii, false)) {
        reject(domain, message.invalidDomain());
      }
    }
  }

  if (!errors.length) {
    return { valid: true, message: '', annotations: [] };
  }

  annotations.sort((left, right) => left.start - right.start);

  return { valid: false, message: errors.join('\n'), annotations };
}
