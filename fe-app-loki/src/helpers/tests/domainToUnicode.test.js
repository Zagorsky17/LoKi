import { domainToUnicode as nodeDomainToUnicode } from 'url';

import { describe, expect, it } from 'vitest';

import { domainToUnicode } from '../domainToUnicode';

describe('domainToUnicode', () => {
  it.each([
    'xn--d1abbgf6aiiy.xn--p1ai',
    'xn--e1afmkfd.xn--p1ai',
    'xn--80aswg.xn--p1acf',
    'xn--80adxhks.xn--80asehdb',
    'xn--mnchen-3ya.de',
    'www.xn--fiqs8s',
    'xn--e1afmkfd.xn--80akhbyknj4f',
  ])('reads %s as its letters', (domain) => {
    expect(domainToUnicode(domain)).toBe(nodeDomainToUnicode(domain));
  });

  it('turns a Cyrillic domain back into Cyrillic', () => {
    expect(domainToUnicode('xn--d1abbgf6aiiy.xn--p1ai')).toBe('президент.рф');
    expect(domainToUnicode('XN--E1AFMKFD.XN--P1AI')).toBe('пример.рф');
  });

  it('leaves an ASCII name and an address as they are', () => {
    expect(domainToUnicode('i.ytimg.com')).toBe('i.ytimg.com');
    expect(domainToUnicode('149.154.167.50')).toBe('149.154.167.50');
    expect(domainToUnicode('fddb:33d1:f8bc::1')).toBe('fddb:33d1:f8bc::1');
  });

  it('keeps a look-alike that mixes Latin with another script as ASCII', () => {
    expect(nodeDomainToUnicode('xn--pple-43d.com')).toBe('аpple.com');
    expect(domainToUnicode('xn--pple-43d.com')).toBe('xn--pple-43d.com');
  });

  it('keeps a label that is not valid Punycode as it came', () => {
    expect(domainToUnicode('xn--.com')).toBe('xn--.com');
    expect(domainToUnicode('xn--a!b.com')).toBe('xn--a!b.com');
  });
});
