import { message } from '../../../validators/messages';

// Takes the value alone, for list fields and other sections' dialogs. RE2 writes a leading (?i)
// and named groups as JavaScript cannot; the backend refuses what RE2 and Loki would read
// differently.
export function validateRegex(value: string) {
  if (!value || !value.length) {
    return true;
  }

  try {
    new RegExp(value.replace(/^\(\?i\)/, '').replace(/\(\?P</g, '(?<'));
    return true;
  } catch (_error) {
    return message.invalidRegex();
  }
}
