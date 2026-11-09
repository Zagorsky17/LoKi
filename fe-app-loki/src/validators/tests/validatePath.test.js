import { describe, expect, it } from 'vitest';
import { validatePath } from '../validatePath';

export const validPaths = [
  ['Single level', '/etc'],
  ['Nested path', '/usr/local/bin'],
  ['With dash', '/var/log/nginx-access'],
  ['With underscore', '/opt/my_app/config'],
  ['With numbers', '/data123/files'],
  ['With dots', '/home/user/.config'],
  ['Deep nested', '/a/b/c/d/e/f/g'],
];

export const invalidPaths = [
  ['Empty string', ''],
  ['Missing starting slash', 'usr/local'],
  ['Only dot', '.'],
  ['Space inside', '/path with space'],
  ['Illegal char', '/path$'],
  ['Backslash not allowed', '\\windows\\path'],
  ['Relative path ./', './relative'],
  ['Relative path ../', '../parent'],
];

describe('validatePath', () => {
  describe.each(validPaths)('Valid path: %s', (_desc, path) => {
    it(`returns true for "${path}"`, () => {
      const res = validatePath(path);
      expect(res).toBe(true);
    });
  });

  describe.each(invalidPaths)('Invalid path: %s', (_desc, path) => {
    it(`returns a reason for "${path}"`, () => {
      const res = validatePath(path);
      expect(res).not.toBe(true);
    });
  });
});
