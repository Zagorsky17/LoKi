// The cell, the device filter and the search read the same description, so the filter offers
// exactly what the column shows.

export interface SourceConnection {
  metadata?: {
    sourceIP?: string;
    type?: string;
    user?: string;
  };
  rule?: string;
}

export interface SourceNames {
  // Device address to the name the router knows it by.
  devices: Record<string, string>;
}

export type SourceKind = 'system' | 'device';

export interface ConnectionSource {
  // The device filter value.
  key: string;
  kind: SourceKind;
  // The main text, and the muted detail beside it; an address is always the detail.
  name: string;
  detail: string;
  search: string;
}

const SYSTEM_SOURCE_KEY = '@system';
const SYSTEM_INBOUND_TAGS = new Set(['system-in', 'system6-in']);
const KIND_ORDER: SourceKind[] = ['system', 'device'];
const collator = new Intl.Collator(undefined, {
  numeric: true,
  sensitivity: 'base',
});

function text(value?: string | number | null): string {
  return value == null ? '' : String(value).trim();
}

function isLoopback(ip: string): boolean {
  return ip === '::1' || /^(::ffff:)?127\./.test(ip);
}

function connectionInboundTag(connection: SourceConnection): string {
  const type = text(connection.metadata?.type);
  const tag = text(type.split('/').slice(1).join('/') || type);

  if (tag) {
    return tag;
  }

  return text(text(connection.rule).match(/(?:^|\s)inbound=([^\s]+)/)?.[1]);
}

// The source as plain text, where no colour can mute the detail.
export function sourceLabel(name: string, detail: string): string {
  return [name, detail].filter(Boolean).join(' · ');
}

export function describeSource(
  connection: SourceConnection,
  names: SourceNames,
): ConnectionSource {
  const ip = text(connection.metadata?.sourceIP);
  const tag = connectionInboundTag(connection);
  const search = (...values: string[]) =>
    [...values, ip, tag].filter(Boolean).join(' ');

  // The router's own requests also reach a local proxy inbound such as the WARP dialog's.
  if (SYSTEM_INBOUND_TAGS.has(tag) || isLoopback(ip)) {
    const name = _('System');
    return {
      key: SYSTEM_SOURCE_KEY,
      kind: 'system',
      name,
      detail: '',
      search: search(name),
    };
  }

  const name = text(names.devices[ip]);
  return {
    key: ip,
    kind: 'device',
    name,
    detail: ip,
    search: search(name),
  };
}

// The router first, then the devices, named ones before bare addresses.
export function compareSources(a: ConnectionSource, b: ConnectionSource) {
  return (
    KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind) ||
    Number(!a.name) - Number(!b.name) ||
    collator.compare(a.name, b.name) ||
    collator.compare(a.detail, b.detail) ||
    a.key.localeCompare(b.key)
  );
}
