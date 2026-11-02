// Mirrors FILTERABLE_PROVIDER_TYPES in the backend: providers build nodes from outbounds only.
export function providerTypeChoices() {
  return [
    ['vless', 'VLESS'],
    ['vmess', 'VMess'],
    ['trojan', 'Trojan'],
    ['shadowsocks', 'Shadowsocks'],
    ['hysteria2', 'Hysteria2'],
    ['hysteria', 'Hysteria'],
    ['tuic', 'TUIC'],
    ['anytls', 'AnyTLS'],
    ['naive', 'NaiveProxy'],
    ['mieru', 'Mieru'],
    ['snell', 'Snell'],
    ['shadowtls', 'ShadowTLS'],
    ['trusttunnel', 'TrustTunnel'],
    ['ssh', 'SSH'],
    ['tor', 'Tor'],
    ['socks', 'SOCKS'],
    ['http', 'HTTP'],
  ].map(([value, label]) => ({ value, label }));
}

// Groups also hold the section's interface connections.
export function groupTypeChoices() {
  return [
    ...providerTypeChoices(),
    ...[['direct', _('Network interface')]].map(([value, label]) => ({
      value,
      label,
    })),
  ];
}
