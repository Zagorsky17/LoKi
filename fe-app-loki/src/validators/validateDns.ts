import { validateDomain } from './validateDomain';
import { isValidPort, parseHostPort, unbracketHost } from './hostPort';
import { message } from './messages';
import { Check } from './types';
import { validateIP } from './validateIp';

const DNS_SCHEMES = new Set(['udp', 'tcp', 'tls', 'https', 'quic', 'h3']);

export function validateDNS(value: string, ipOnly = false): Check {
  const normalized = `${value || ''}`.trim();
  if (!normalized) {
    return message.required();
  }

  const invalid = _('Invalid DNS server');
  if (/[\s@?#]/.test(normalized)) {
    return invalid;
  }

  const schemeMatch = normalized.match(/^([a-z][a-z0-9+.-]*):\/\//i);
  const scheme = schemeMatch?.[1].toLowerCase() || 'udp';
  if (!DNS_SCHEMES.has(scheme)) {
    return _('Protocol %s is not supported').format(`${scheme}://`);
  }

  const endpoint = schemeMatch
    ? normalized.slice(schemeMatch[0].length)
    : normalized;
  const slash = endpoint.indexOf('/');
  const authority = slash >= 0 ? endpoint.slice(0, slash) : endpoint;
  const path = slash >= 0 ? endpoint.slice(slash) : '';
  if (path && scheme !== 'https' && scheme !== 'h3') {
    return _('A path only with https:// and h3://');
  }

  const parsedHostPort = parseHostPort(authority);
  const host = parsedHostPort ? parsedHostPort.host : unbracketHost(authority);

  if (parsedHostPort && !isValidPort(parsedHostPort.port)) {
    return message.invalidPort();
  }

  if (validateIP(host) === true) {
    return true;
  }

  if (ipOnly) {
    return _('IP address only');
  }

  return validateDomain(host) === true ? true : invalid;
}
