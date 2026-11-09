// TrustTunnel's deep link, as its DEEP_LINK.md defines it: tt://? and tag-length-value fields in
// unpadded base64url, tags and lengths as QUIC variable-length integers.

// A parser refuses a version newer than its own, and TrustTunnel's stable releases (endpoint
// 1.1, client 1.1.11) read only version 1; version 2 adds no field these links carry.
const FORMAT_VERSION = 1;
const HTTP3 = 2;

const FIELD = {
  version: 0x00,
  hostname: 0x01,
  address: 0x02,
  customSni: 0x03,
  username: 0x05,
  password: 0x06,
  skipVerification: 0x07,
  certificate: 0x08,
  upstreamProtocol: 0x09,
  name: 0x0c,
};

export interface TrustTunnelLink {
  // The name the client checks the certificate against, and sends as SNI unless
  // customSni is set.
  hostname: string;
  // host:port, an IPv6 address in brackets.
  address: string;
  customSni?: string;
  username: string;
  password: string;
  skipVerification?: boolean;
  // DER, the only certificate the client then trusts.
  certificate?: Uint8Array;
  http3?: boolean;
  name?: string;
}

function writeVarint(value: number) {
  if (value < 0x40) return [value];
  if (value < 0x4000) return [0x40 | (value >> 8), value & 0xff];
  return [
    0x80 | ((value >>> 24) & 0x3f),
    (value >>> 16) & 0xff,
    (value >>> 8) & 0xff,
    value & 0xff,
  ];
}

function readVarint(bytes: Uint8Array, offset: number) {
  if (offset >= bytes.length) {
    return null;
  }
  const length = 1 << (bytes[offset] >> 6);
  if (offset + length > bytes.length) {
    return null;
  }
  let value = bytes[offset] & 0x3f;
  for (let index = 1; index < length; index++) {
    value = value * 256 + bytes[offset + index];
  }
  return { value, next: offset + length };
}

function field(tag: number, value: ArrayLike<number>) {
  return [
    ...writeVarint(tag),
    ...writeVarint(value.length),
    ...Array.from(value),
  ];
}

function text(value: string) {
  return new TextEncoder().encode(value);
}

// In the order of TrustTunnel's own encoder, so the link matches the one its endpoint exports.
export function encodeTrustTunnelLink(link: TrustTunnelLink) {
  const payload = [
    ...field(FIELD.version, writeVarint(FORMAT_VERSION)),
    ...field(FIELD.hostname, text(link.hostname)),
    ...field(FIELD.username, text(link.username)),
    ...field(FIELD.password, text(link.password)),
    ...field(FIELD.address, text(link.address)),
    ...(link.customSni ? field(FIELD.customSni, text(link.customSni)) : []),
    ...(link.skipVerification ? field(FIELD.skipVerification, [1]) : []),
    ...(link.certificate ? field(FIELD.certificate, link.certificate) : []),
    ...(link.http3 ? field(FIELD.upstreamProtocol, writeVarint(HTTP3)) : []),
    ...(link.name ? field(FIELD.name, text(link.name)) : []),
  ];
  const encoded = btoa(String.fromCharCode(...payload))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
  return `tt://?${encoded}`;
}

// The name field of the payload after "tt://", or ''.
export function trustTunnelLinkName(source: string) {
  const encoded = source
    .replace(/^\?/, '')
    .replace(/-/g, '+')
    .replace(/_/g, '/');
  let payload: Uint8Array;
  try {
    payload = Uint8Array.from(
      atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, '=')),
      (character) => character.charCodeAt(0),
    );
  } catch {
    return '';
  }

  let name = '';
  for (let offset = 0; offset < payload.length; ) {
    const tag = readVarint(payload, offset);
    const size = tag && readVarint(payload, tag.next);
    if (!size || size.next + size.value > payload.length) {
      return '';
    }
    if (tag.value === FIELD.name) {
      name = new TextDecoder().decode(
        payload.subarray(size.next, size.next + size.value),
      );
    }
    offset = size.next + size.value;
  }
  return name;
}
