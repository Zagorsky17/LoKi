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
    location.protocol !== 'https:'
  );
}

export function getClashWsUrl(): string {
  const { hostname } = window.location;

  return `ws://${hostname}:9090`;
}

// A Clash API socket, which takes the controller secret in its query.
export function getClashSocketUrl(path: string, secret: string): string {
  return `${getClashWsUrl()}${path}?token=${encodeURIComponent(secret)}`;
}

export function getClashApiUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090`;
}

export function getClashUIUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090/ui`;
}

// YACD takes its backend and key from these query values on load, decoding each with
// decodeURIComponent (a "+" stays a "+"), then drops them from the address.
export function getClashUILoginUrl(secret: string): string {
  const { hostname } = window.location;
  const query = Object.entries({ hostname, port: '9090', secret })
    .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
    .join('&');

  return `${getClashUIUrl()}/?${query}`;
}
