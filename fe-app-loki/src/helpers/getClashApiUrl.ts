function getWindowLocation(): Location | undefined {
  return typeof window !== 'undefined' ? window.location : undefined;
}

export function canUseDirectClashApi(): boolean {
  const location = getWindowLocation();

  return (
    typeof L !== 'undefined' &&
    L.hasViewPermission?.() === true &&
    typeof location?.hostname === 'string' &&
    location.hostname !== '' &&
    location.protocol === 'https:'
  );
}

export function getClashWsUrl(): string {
  return getClashApiUrl().replace(/^https:/, 'wss:');
}

export function getClashSocketUrl(path: string): string {
  return `${getClashWsUrl()}${path}`;
}

export function getClashApiUrl(): string {
  return `https://${window.location.hostname}:9091/cgi-bin/luci/loki-gateway/api`;
}

export function getClashUIUrl(): string {
  return `https://${window.location.hostname}:9091/cgi-bin/luci/loki-gateway/`;
}
