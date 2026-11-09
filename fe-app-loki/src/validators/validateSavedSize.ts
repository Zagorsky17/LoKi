import { Check } from './types';

// LuCI refuses a request body over 100 KiB (HTTP_MAX_CONTENT of luci/http.uc) and saves none of it,
// and a save sends the changed values in one request; the rest is room for the call around them.
export const MAX_SAVED_KB = 96;

export function validateSavedSize(value: unknown): Check {
  const bytes = new TextEncoder().encode(JSON.stringify(`${value ?? ''}`));
  const kilobytes = Math.ceil(bytes.length / 1024);
  return kilobytes <= MAX_SAVED_KB
    ? true
    : _('At most %d KB, this is %d KB').format(MAX_SAVED_KB, kilobytes);
}
