import type { ClashAPIConfig, LogsAPIConfig } from '~/types';

const apiPrefix = '/cgi-bin/luci/loki-gateway/api';
const headersCommon = { 'Content-Type': 'application/json', 'X-Loki-CSRF': '1' };

function gatewayURL() {
  if (window.location.protocol !== 'https:') throw new Error('YACD requires HTTPS');
  return window.location.origin + apiPrefix;
}
function buildWebSocketURLBase(params: URLSearchParams, endpoint: string) {
  const query = params.toString();
  return `${gatewayURL().replace(/^https:/, 'wss:')}${endpoint}${query ? '?' + query : ''}`;
}

export function getURLAndInit(_config: ClashAPIConfig) {
  return {
    url: gatewayURL(),
    init: { headers: headersCommon, credentials: 'same-origin' as const, cache: 'no-store' as const },
  };
}

export async function readErrorMessage(res: Response, _logLabel: string) {
  // Core errors can echo connection URLs and credentials; never surface their body.
  return `Request failed (HTTP ${res.status})`;
}

export function buildWebSocketURL(_apiConfig: ClashAPIConfig, endpoint: string) {
  return buildWebSocketURLBase(new URLSearchParams(), endpoint);
}

export function buildLogsWebSocketURL(apiConfig: LogsAPIConfig, endpoint: string) {
  return buildWebSocketURLBase(new URLSearchParams({ level: apiConfig.logLevel }), endpoint);
}
