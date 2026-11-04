import { Check } from './types';
import { validatePath } from './validatePath';

// Both paths are write targets, so the expected file name and a parent directory keep a stray
// value from overwriting an unrelated file or landing in the root.
export function validateSingBoxFilePath(
  value: string,
  fileName: string,
): Check {
  const path = validatePath(value);
  if (path !== true) {
    return path;
  }

  if (!value.endsWith(fileName)) {
    return _('Path must end with %s').format(fileName);
  }

  return value.split('/').filter(Boolean).length < 2
    ? _('Format: %s').format(`/tmp/${fileName}`)
    : true;
}
