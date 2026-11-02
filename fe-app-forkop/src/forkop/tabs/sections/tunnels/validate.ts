import { validateCoreFeature } from '../../../services/coreFeatures.service';
import { tunnelCoreFeature } from '../coreSupport';
import { message } from '../../../../validators/messages';
import { hostField, portField } from '../../../../validators/fields';
import { validateSubnet } from '../../../../validators/validateSubnet';
import { validateTailscaleHostname } from '../../../../validators/validateTailscaleHostname';
import { validateUrl } from '../../../../validators/validateUrl';
import { isExistingChildItem } from '../../../cbi/childItems';
import { validateOpenVPNSettings } from './openvpn';
import { validateOpenConnectSettings } from './openconnect';
import { normalizeDynamicListItems } from '../../../cbi/listValues';
import {
  AMNEZIA_KEYS,
  ONE_SIDED_AMNEZIA_KEYS,
  parseUnsigned,
  validateAmneziaSet,
  validateAmneziaValue,
  validateRange,
  validateWireGuardKey,
} from '../../../../helpers/wireguard';
import {
  WIREGUARD_PEER_FIELDS,
  oneSidedAmneziaEnabled,
  tunnelDisplayName,
  tunnelEndpointFromSettings,
  tunnelInitialSettings,
  tunnelPeerForValue,
  wireGuardPeerDisplayNameFromObject,
} from './model';

// These judge a tunnel or peer whose dialog is closed: the entry is only told to be fixed, and a
// rule spanning several fields is said in full.

export function validateWireGuardPrefix(value: unknown) {
  const address = typeof value === 'string' ? value.trim() : '';
  return address.includes('/')
    ? validateSubnet(address)
    : message.prefixLength();
}

export function validateAmneziaRange(value: unknown) {
  const normalized = `${value || ''}`.trim();
  return !normalized || validateRange(normalized);
}

function isKeepalive(value: unknown) {
  return typeof value === 'string'
    ? validateAmneziaRange(value) === true
    : typeof value === 'number' &&
        Number.isInteger(value) &&
        value >= 0 &&
        value <= 0xffffffff;
}

function wireGuardPeerComplete(peer: WireGuardPeerObject) {
  const allowedIps = Array.isArray(peer.allowed_ips)
    ? peer.allowed_ips
    : peer.allowed_ips != null
      ? [peer.allowed_ips]
      : [];
  return (
    typeof peer.address === 'string' &&
    hostField('', peer.address) === true &&
    !!peer.address.trim() &&
    typeof peer.port === 'number' &&
    portField('', peer.port) === true &&
    typeof peer.public_key === 'string' &&
    validateWireGuardKey(peer.public_key) &&
    Object.keys(peer).every((key: string) => WIREGUARD_PEER_FIELDS.has(key)) &&
    (peer.pre_shared_key == null ||
      (typeof peer.pre_shared_key === 'string' &&
        validateWireGuardKey(peer.pre_shared_key))) &&
    allowedIps.length > 0 &&
    allowedIps.every(
      (allowedIp: string) => validateWireGuardPrefix(allowedIp) === true,
    ) &&
    (peer.persistent_keepalive_interval == null ||
      isKeepalive(peer.persistent_keepalive_interval))
  );
}

export function validateWireGuardPeerValue(
  value: unknown,
  tunnelId: string,
  option: CBIOption,
) {
  const peer = tunnelPeerForValue(tunnelId, value, option);
  return peer && wireGuardPeerComplete(peer)
    ? true
    : message.item(
        peer ? wireGuardPeerDisplayNameFromObject(peer) : '',
        message.fixSettings(),
      );
}

export function validateWireGuardPeers(
  values: unknown,
  tunnelId?: string,
  option?: CBIOption,
) {
  const peers = L.toArray(values).filter((value: unknown) =>
    `${value || ''}`.trim(),
  );
  if (peers.length === 0) {
    return message.required();
  }
  for (const value of peers) {
    const validation = validateWireGuardPeerValue(
      value,
      `${tunnelId ?? ''}`,
      option!,
    );
    if (validation !== true) return validation;
  }
  return true;
}

// Empty, or a whole number from minimum to 65535.
function isOptionalUint16(value: unknown, minimum: number) {
  const text = `${value ?? ''}`.trim();
  const parsed = parseUnsigned(text, 65535);
  return !text || (parsed !== undefined && parsed >= minimum);
}

function amneziaProblem(kind: string, settings: ChildSettings) {
  if (kind !== 'amneziawg' && !oneSidedAmneziaEnabled(kind, settings)) {
    return true;
  }
  const keys = kind === 'amneziawg' ? AMNEZIA_KEYS : ONE_SIDED_AMNEZIA_KEYS;
  const values: Record<string, unknown> = {};
  for (const key of keys) {
    values[key] = settings[`amnezia_${key}`];
    if (validateAmneziaValue(key, values[key]) !== true) {
      return message.fixSettings();
    }
  }
  return validateAmneziaSet(values);
}

function warpComplete(
  settings: ChildSettings,
  endpoint: NonNullable<ReturnType<typeof tunnelEndpointFromSettings>>,
) {
  return (
    hostField('', settings.warp_address) === true &&
    isOptionalUint16(settings.warp_port, 0) &&
    validateAmneziaRange(settings.warp_keepalive) === true &&
    [
      endpoint.profile?.id,
      endpoint.profile?.auth_token,
      endpoint.profile?.private_key,
    ].every(Boolean)
  );
}

export function validateTunnelSettings(
  settings: ChildSettings,
  tunnelId?: string,
  peerOption?: CBIOption,
) {
  const kind = `${settings.tunnel_type || ''}`;
  const core = validateCoreFeature(
    tunnelCoreFeature(kind, settings.endpoint_json),
  );
  if (core !== true) {
    return core;
  }
  if (kind !== 'json' && !`${settings.name || ''}`.trim()) {
    return message.fixSettings();
  }
  if (kind === 'openvpn-client') {
    return validateOpenVPNSettings(settings);
  }
  if (kind === 'openconnect') {
    return validateOpenConnectSettings(settings);
  }
  const endpoint = tunnelEndpointFromSettings(settings, tunnelId, peerOption);
  if (!endpoint) {
    return message.fixSettings();
  }
  if (`${endpoint.type || ''}`.trim().toLowerCase() === 'openvpn-server') {
    return _('VPN server endpoints are not supported');
  }
  if (kind === 'json') {
    return typeof endpoint.tag === 'string' && endpoint.tag.trim()
      ? true
      : message.fixSettings();
  }
  if (endpoint.type === 'tailscale') {
    return endpoint.auth_key &&
      validateTailscaleHostname(endpoint.hostname) === true &&
      validateUrl(endpoint.control_url || '') === true &&
      (`${settings.tailscale_detour_enabled || ''}` !== '1' || endpoint.detour)
      ? true
      : message.fixSettings();
  }
  const amnezia = amneziaProblem(kind, settings);
  if (amnezia !== true) {
    return amnezia;
  }
  if (endpoint.type === 'warp') {
    return warpComplete(settings, endpoint) ? true : message.fixSettings();
  }
  if (
    !isOptionalUint16(settings.listen_port, 0) ||
    !isOptionalUint16(settings.mtu, 1) ||
    !endpoint.private_key ||
    !validateWireGuardKey(endpoint.private_key) ||
    endpoint.address.length === 0 ||
    endpoint.address.some(
      (address: string) => validateWireGuardPrefix(address) !== true,
    ) ||
    endpoint.peers.length === 0 ||
    validateWireGuardPeers(settings.peer_ids, tunnelId, peerOption) !== true
  ) {
    return message.fixSettings();
  }
  if (
    kind === 'amneziawg' &&
    Object.keys(endpoint.amnezia || {}).length === 0
  ) {
    return _('Add at least one AmneziaWG parameter');
  }
  return true;
}

// One tunnel of a section's list, named where the list stands.
export function validateTunnelItem(section_id: string, tunnelId: string) {
  const validation = isExistingChildItem(section_id, tunnelId, 'tunnel')
    ? validateTunnelSettings(tunnelInitialSettings(tunnelId, section_id))
    : message.fixSettings();
  return validation === true
    ? true
    : message.item(
        tunnelDisplayName(section_id, tunnelId) || _('Tunnel'),
        validation,
      );
}

export function validateTunnelItemsBeforeSave(
  section_id: string,
  values: unknown,
) {
  for (const value of normalizeDynamicListItems(values)) {
    const validation = validateTunnelItem(section_id, `${value || ''}`.trim());
    if (validation !== true) {
      return validation;
    }
  }
  return true;
}
