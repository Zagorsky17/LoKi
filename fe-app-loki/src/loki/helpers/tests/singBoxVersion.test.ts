import { describe, expect, it } from 'vitest';
import { formatSingBoxVersion } from '../singBoxVersion';

describe('formatSingBoxVersion', () => {
  it('shows the installed version, or that none is installed', () => {
    expect(
      formatSingBoxVersion({
        sing_box_version: '1.13.14-extended-2.5.2-loki.1',
      }),
    ).toBe('1.13.14-extended-2.5.2-loki.1');
    expect(formatSingBoxVersion({ sing_box_version: 'not installed' })).toBe(
      'Not installed',
    );
    expect(formatSingBoxVersion({})).toBe('Not installed');
  });
});
