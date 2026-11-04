import { isValidHost, isValidPort } from './hostPort';
import { message } from './messages';
import { Check } from './types';

export function validateUrl(
  url: string,
  protocols = ['http:', 'https:'],
): Check {
  if (!protocols.some((p) => url.indexOf(p + '//') === 0)) {
    return url.length
      ? _('Only %s').format(protocols.map((p) => `${p}//`).join(', '))
      : message.invalidUrl();
  }

  try {
    const parsed = new URL(url);
    const host = parsed.hostname.startsWith('[')
      ? parsed.hostname.slice(1, -1)
      : parsed.hostname;
    return (isValidHost(host) || host === 'localhost') &&
      (!parsed.port || isValidPort(parsed.port))
      ? true
      : message.invalidUrl();
  } catch (_e) {
    return message.invalidUrl();
  }
}

// The check every required URL field runs.
export function validateUrlField(value: unknown) {
  const url = `${value || ''}`.trim();
  return url ? validateUrl(url) : message.required();
}
