import { describe, expect, it } from 'vitest';

import { installUciStub } from './luciStubs';
import {
  analyzeDestinationText,
  analyzeDnsDestinationText,
} from '../../loki/tabs/sections/conditions';

installUciStub();

function problems(analyze, text) {
  const analysis = analyze(text);
  return analysis.valid ? [] : analysis.message.split('\n');
}

describe('a routing section', () => {
  it('takes domains of every kind and addresses side by side', () => {
    expect(
      problems(
        analyzeDestinationText,
        'example.org, full:api.example.org keyword:video\n' +
          'regex:^ads[.]\n192.0.2.1 198.51.100.0/24 # office\n' +
          '2001:db8::1, 2001:db8::/32 ::ffff:192.0.2.1',
      ),
    ).toEqual([]);
  });

  it.each([
    ['192.0.2', 'Invalid IP address or subnet'],
    ['192.0.2.256', 'Invalid IP address or subnet'],
    ['192.0.2.0/33', 'Prefix length from 0 to 32'],
    ['2001:db8:::1', 'Invalid IP address or subnet'],
    ['dead:beef', 'Invalid IP address or subnet'],
  ])('tells a mistyped address %s what an address needs', (entry, message) => {
    expect(problems(analyzeDestinationText, entry)).toEqual([
      `${entry}: ${message}`,
    ]);
  });

  it.each(['example.123', 'full:192.0.2', 'example.org/24'])(
    'refuses %s, which is neither a domain nor an address',
    (entry) => {
      expect(problems(analyzeDestinationText, entry)).toEqual([
        `${entry}: Invalid domain`,
      ]);
    },
  );

  it('reads a number behind a prefix as the domain condition it names', () => {
    expect(
      problems(analyzeDestinationText, 'keyword:192.0.2\nregex:^10[.]'),
    ).toEqual([]);
  });

  it('counts an address written twice as one, whatever its case', () => {
    expect(
      problems(analyzeDestinationText, '2001:DB8::1\n2001:db8::1'),
    ).toHaveLength(1);
  });
});

describe('a DNS section', () => {
  it('takes domains of every kind', () => {
    expect(
      problems(
        analyzeDnsDestinationText,
        'example.org full:api.example.org keyword:video regex:^ads[.]',
      ),
    ).toEqual([]);
  });

  it.each(['192.0.2.1', '198.51.100.0/24', '2001:db8::/32'])(
    'refuses the address %s it could never match',
    (entry) => {
      expect(
        problems(analyzeDnsDestinationText, `example.org\n${entry}`),
      ).toEqual([`${entry}: Domains only`]);
    },
  );
});
