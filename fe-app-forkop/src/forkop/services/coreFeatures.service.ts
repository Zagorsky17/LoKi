import { callUbus } from '../../helpers/callUbus';
import { ForkopShellMethods } from '../methods/shell';
import type { Forkop } from '../types';
import {
  FORKOP_CALL_TIMEOUT_MS,
  FORKOP_SERVICE_OBJECT,
} from './forkopWaitTransport';

type CoreTypeKind = 'outbound' | 'endpoint';

// What the installed sing-box can do, as singbox/features.uc reads it. Until the router answers,
// and without a core, everything counts as available: the router still refuses what it cannot run.
let report: Forkop.CoreFeatures | null = null;

// Answers from the state service carry the report; the CLI's leave the last one in place.
export function setCoreFeatures(value: Forkop.CoreFeatures | null | undefined) {
  if (value === undefined) {
    return;
  }
  report = value && value.known ? value : null;
}

export function coreHas(feature: string) {
  return !report || report.features[feature]?.available !== false;
}

export function coreFeatureTags(feature: string) {
  return report?.features[feature]?.tags || [];
}

// A group member is an outbound or an endpoint, so both are checked unless a kind is named.
export function coreFeatureOfType(
  type: string,
  kinds: CoreTypeKind[] = ['outbound', 'endpoint'],
) {
  for (const kind of kinds) {
    const feature = report?.types[kind]?.[type];
    if (feature) {
      return feature;
    }
  }
  return '';
}

export function coreSupportsType(type: string, kinds?: CoreTypeKind[]) {
  const feature = coreFeatureOfType(type, kinds);
  return !feature || coreHas(feature);
}

export function coreHasAnyEndpoint() {
  return (
    !report ||
    Object.values(report.types.endpoint || {}).some((feature) =>
      coreHas(feature),
    )
  );
}

// The tags a feature needs that the installed core was built without.
export function missingCoreTags(feature: string) {
  const present = new Set(report?.tags || []);
  return coreFeatureTags(feature).filter((tag) => !present.has(tag));
}

// What a choice the build lacks says about itself.
export function missingCoreFeatureNote(feature: string) {
  return _('the installed sing-box lacks %s').format(
    missingCoreTags(feature).join(', '),
  );
}

// The refusal of a value the build lacks, or true.
export function validateCoreFeature(feature: string) {
  return !feature || coreHas(feature)
    ? true
    : _('sing-box is built without %s').format(
        missingCoreTags(feature).join(', '),
      );
}

// Types the core dials over TLS whether or not their link says so.
const ALWAYS_TLS_TYPES = new Set([
  'trojan',
  'tuic',
  'hysteria',
  'hysteria2',
  'anytls',
]);

function linkQuery(link: string) {
  const start = link.indexOf('?');
  const query = new Map<string, string>();
  if (start < 0) {
    return query;
  }
  const text = link.slice(start + 1).split('#')[0];
  for (const pair of text.split('&')) {
    const equals = pair.indexOf('=');
    const key = (equals < 0 ? pair : pair.slice(0, equals)).toLowerCase();
    if (key && !query.has(key)) {
      query.set(key, equals < 0 ? '' : pair.slice(equals + 1));
    }
  }
  return query;
}

// A VMess link is either the base64 JSON v2rayN writes or a URL with a query.
function vmessPayload(link: string) {
  const body = link
    .slice(link.indexOf('://') + 3)
    .split('#')[0]
    .replace(/-/g, '+')
    .replace(/_/g, '/');
  try {
    const payload = JSON.parse(
      atob(body.padEnd(body.length + ((4 - (body.length % 4)) % 4), '=')),
    );
    return payload && typeof payload === 'object' && !Array.isArray(payload)
      ? payload
      : null;
  } catch {
    return null;
  }
}

// A fingerprint on a TLS link, or Reality, which always sends one; singbox/features.uc reads
// links the same way.
function linkUsesUtls(type: string, link: string) {
  if (type === 'vmess') {
    const payload = vmessPayload(link);
    if (payload) {
      const tls = `${payload.tls ?? ''}`.toLowerCase();
      return (
        (tls === 'tls' ||
          tls === '1' ||
          tls === 'true' ||
          payload.net === 'h2') &&
        `${payload.fp ?? ''}` !== ''
      );
    }
  }
  const query = linkQuery(link);
  const security = (query.get('security') || '').toLowerCase();
  if (security === 'reality' || query.get('pbk')) {
    return true;
  }
  const tls =
    ALWAYS_TLS_TYPES.has(type) || security === 'tls' || security === 'xtls';
  return tls && Boolean(query.get('fp') || query.get('client-fingerprint'));
}

function queryValue(value: string | undefined) {
  try {
    return decodeURIComponent(value || '').trim();
  } catch {
    return `${value || ''}`.trim();
  }
}

// The core runs XHTTP over HTTP/3, as Xray does, when TLS other than Reality offers h3 alone; the
// parameters are Xray's, read as singbox/features.uc reads them.
function linkUsesXhttpHttp3(type: string, link: string) {
  if (
    !['vless', 'vmess', 'trojan'].includes(type) ||
    (type === 'vmess' && vmessPayload(link))
  ) {
    return false;
  }
  const query = linkQuery(link);
  const transport =
    queryValue(query.get('type')) || queryValue(query.get('net'));
  const security = queryValue(query.get('security')).toLowerCase();
  const reality = security === 'reality' || Boolean(query.get('pbk'));
  const alpn = queryValue(query.get('alpn'))
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
  return (
    (transport === 'xhttp' || transport === 'splithttp') &&
    (type === 'trojan' || ['tls', 'xtls'].includes(security)) &&
    !reality &&
    alpn.length === 1 &&
    alpn[0] === 'h3'
  );
}

// The features a share link needs from the core that will parse it.
export function linkCoreFeatures(link: string) {
  const value = `${link || ''}`.trim();
  const separator = value.indexOf('://');
  const scheme = separator > 0 ? value.slice(0, separator).toLowerCase() : '';
  const type = report?.links[scheme] || '';
  const features: string[] = [];
  const feature = coreFeatureOfType(type, ['outbound']);
  if (feature) {
    features.push(feature);
  }
  if (linkUsesXhttpHttp3(type, value)) {
    features.push('quic');
  }
  if (report && linkUsesUtls(type, value)) {
    features.push('utls');
  }
  return features;
}

// The state service answers from memory; the CLI, which runs the core, answers without it.
export async function loadCoreFeatures() {
  const served = await callUbus<Forkop.UiState>({
    object: FORKOP_SERVICE_OBJECT,
    method: 'state',
    timeoutMs: FORKOP_CALL_TIMEOUT_MS,
    retryUnavailable: false,
  });
  if (served.success && served.data?.capabilities?.core) {
    setCoreFeatures(served.data.capabilities.core);
    return;
  }

  const answer = await ForkopShellMethods.getCoreFeatures();
  if (answer.success) {
    setCoreFeatures(answer.data);
  }
}
