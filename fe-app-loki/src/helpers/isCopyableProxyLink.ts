const COPYABLE_PROXY_URI_RE =
  /^(anytls|http2|http3|https?|naive\+https|naive\+quic|mieru|mierus|vless|vmess|trojan|ss|hysteria|hysteria2|hy2|tuic|socks|socks4|socks4a|socks5|tt):\/\//i;

export function isCopyableProxyLink(link?: string) {
  return COPYABLE_PROXY_URI_RE.test((link || '').trim());
}
