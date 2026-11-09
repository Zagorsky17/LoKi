import { message } from './messages';
import { Check } from './types';

export function validatePath(value: string): Check {
  if (!value) {
    return message.required();
  }

  return /^\/[a-zA-Z0-9_\-/.]+$/.test(value) ? true : message.invalidPath();
}
