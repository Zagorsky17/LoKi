import { describe, expect, it } from 'vitest';

import { nextNumberedName } from '../nextNumberedName';

describe('nextNumberedName', () => {
  it('starts at one among entries the user named', () => {
    expect(nextNumberedName('URLTest', ['test', 'Fastest'])).toBe('URLTest #1');
  });

  it('is one past the highest number taken, not one past the count', () => {
    expect(
      nextNumberedName('Server', [
        'Server #1',
        'Server #2',
        'Server #3',
        'Server #5',
        'Server #6',
      ]),
    ).toBe('Server #7');
    expect(nextNumberedName('URLTest', ['URLTest #2'])).toBe('URLTest #3');
  });

  it('reads only the names numbered under its own prefix', () => {
    expect(
      nextNumberedName('Tunnel', [
        'Fallback #4',
        'My Tunnel #9',
        'Tunnel #x',
        ' Tunnel #1 ',
      ]),
    ).toBe('Tunnel #2');
  });

  it('numbers a prefix joined without a separator', () => {
    expect(
      nextNumberedName('sub', ['sub2', 'sub10', 'subway', 'sub #12'], ''),
    ).toBe('sub11');
  });
});
