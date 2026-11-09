import { describe, expect, it } from 'vitest';
import { analyzeStaticHosts } from '../validateStaticHosts.js';

const validRecords = [
  ['single domain', '130.255.77.28 ntc.party'],
  ['several domains', '130.255.77.28 ntc.party www.ntc.party'],
  ['IPv6 address', '2a03:4000::1 ntc.party'],
  ['tab separator', '130.255.77.28\tntc.party'],
  ['single label host', '192.168.1.10 printer'],
  ['comment line', '# just a note'],
  ['trailing comment', '130.255.77.28 ntc.party # pinned'],
  ['empty text', ''],
];

const invalidRecords = [
  ['swapped columns', 'ntc.party 130.255.77.28'],
  ['address only', '130.255.77.28'],
  ['empty label', '130.255.77.28 ntc..party'],
  ['leading dot', '130.255.77.28 .ntc.party'],
  ['subnet instead of address', '130.255.77.0/24 ntc.party'],
  ['url instead of domain', '130.255.77.28 https://ntc.party'],
];

describe('analyzeStaticHosts', () => {
  it.each(validRecords)('accepts %s', (_name, value) => {
    expect(analyzeStaticHosts(value).valid).toBe(true);
  });

  it.each(invalidRecords)('rejects %s', (_name, value) => {
    expect(analyzeStaticHosts(value).valid).toBe(false);
  });

  it('reports the failing entry', () => {
    expect(analyzeStaticHosts('130.255.77.28 ntc..party').message).toContain(
      'ntc..party',
    );
  });

  it('marks only the invalid domain', () => {
    const text = '130.255.77.28 ntc.party ntc..party';
    const { annotations } = analyzeStaticHosts(text);

    expect(annotations).toHaveLength(1);
    expect(text.slice(annotations[0].start, annotations[0].end)).toBe(
      'ntc..party',
    );
  });

  it('marks entries on every line in order', () => {
    const text = 'nope one.example\n130.255.77.28 two..example';
    const { annotations } = analyzeStaticHosts(text);

    expect(annotations.map(({ start, end }) => text.slice(start, end))).toEqual(
      ['nope', 'two..example'],
    );
  });

  it('ignores commented text', () => {
    expect(
      analyzeStaticHosts('130.255.77.28 ntc.party # ntc..party').valid,
    ).toBe(true);
  });
});
