import { describe, expect, it } from 'vitest';

import { getDiagnosticsChecks } from '../diagnostic.store';

describe('the order of the Status checks', () => {
  it('follows what traffic depends on, without a server group', () => {
    const checks = getDiagnosticsChecks('');
    const expected = ['SERVICE', 'DNS', 'TRAFFIC', 'SECTIONS'];

    expect(checks.map((check) => check.code)).toEqual(expected);
    expect(
      [...checks].sort((a, b) => a.order - b.order).map((check) => check.code),
    ).toEqual(expected);
  });

  it('lists only the remaining diagnostics', () => {
    expect(getDiagnosticsChecks('').map((check) => check.code)).toEqual([
      'SERVICE',
      'DNS',
      'TRAFFIC',
      'SECTIONS',
    ]);
  });

  it('omits sections for a configuration without one', () => {
    expect(
      getDiagnosticsChecks('', {
        includeSections: false,
      }).map((check) => check.code),
    ).toEqual(['SERVICE', 'DNS', 'TRAFFIC']);
  });
});
