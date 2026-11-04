import { describe, expect, it } from 'vitest';

import { formatOsRelease } from '../osRelease';

describe('formatOsRelease', () => {
  it('drops the build id from a release build', () => {
    expect(formatOsRelease('ImmortalWrt 24.10.5 r33805-7c4e882aaf6f')).toBe(
      'ImmortalWrt 24.10.5',
    );
    expect(formatOsRelease('OpenWrt 23.05.5 r24106-10cc5fcd00')).toBe(
      'OpenWrt 23.05.5',
    );
  });

  it('drops the build id from a snapshot', () => {
    expect(formatOsRelease('OpenWrt SNAPSHOT r28844-e6b21a2c73')).toBe(
      'OpenWrt SNAPSHOT',
    );
    expect(formatOsRelease('OpenWrt SNAPSHOT r0+28844-e6b21a2c73')).toBe(
      'OpenWrt SNAPSHOT',
    );
  });

  it('keeps a release that carries no build id', () => {
    expect(formatOsRelease('ImmortalWrt 24.10.5')).toBe('ImmortalWrt 24.10.5');
    expect(formatOsRelease('unknown')).toBe('unknown');
    expect(formatOsRelease('loading')).toBe('loading');
  });

  it('never empties a value that is nothing but a build id', () => {
    expect(formatOsRelease('r33805-7c4e882aaf6f')).toBe('r33805-7c4e882aaf6f');
    expect(formatOsRelease('')).toBe('');
  });
});
