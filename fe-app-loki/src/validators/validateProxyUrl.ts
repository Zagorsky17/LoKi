import { Check } from './types';

const NATIVE_PROXY_SCHEMES = new Set([
  'anytls',
  'hysteria',
  'hysteria2',
  'hy2',
  'http',
  'http2',
  'http3',
  'https',
  'mieru',
  'mierus',
  'naive+https',
  'naive+quic',
  'socks',
  'socks4',
  'socks4a',
  'socks5',
  'ss',
  'trojan',
  'tt',
  'tuic',
  'vless',
  'vmess',
]);

// The core reads http(s)://[user:pass@]host[:port][#name] as an HTTP proxy only when
// it names credentials, a port or a node; a path means a web page. Mirrors validator.uc.
function isSubscriptionAddress(link: string) {
  const match = /^https?:\/\/([^/?#]*)([^?#]*)[^#]*(?:#(.*))?$/u.exec(link);
  if (!match) {
    return false;
  }
  const [, authority, path, name] = match;
  const proxy = authority.includes('@') || /:\d+$/u.test(authority) || !!name;
  return (path !== '' && path !== '/') || !proxy;
}

// The name after "#" may hold spaces, which the core's url.Parse takes; control characters it refuses.
export function validateProxyUrl(url: string): Check {
  const link = url.trim();
  const match = /^([a-z0-9+]+):\/\/([^\s#]+)(?:#\P{Cc}*)?$/u.exec(link);
  if (!match || !NATIVE_PROXY_SCHEMES.has(match[1])) {
    return _('Unsupported link');
  }
  return isSubscriptionAddress(link)
    ? _('Probably a subscription URL: paste it into Subscription')
    : true;
}
