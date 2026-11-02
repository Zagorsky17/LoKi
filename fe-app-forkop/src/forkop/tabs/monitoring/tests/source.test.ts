import { describe, expect, it } from 'vitest';

import {
  compareSources,
  describeSource,
  SourceConnection,
  sourceLabel,
} from '../source';

const NAMES = {
  devices: {
    '192.168.1.140': 'POCO-F7',
    '192.168.1.121': 'Redmi-Note-12-Pro-5G',
  },
};

function connection(
  type: string,
  sourceIP: string,
  user = '',
): SourceConnection {
  return { metadata: { type, sourceIP, user } };
}

const describe_ = (value: SourceConnection) => describeSource(value, NAMES);
const label = (value: SourceConnection) => {
  const source = describe_(value);
  return sourceLabel(source.name, source.detail);
};

describe('the source of a Monitoring connection', () => {
  it('names a device the router knows and keeps its address beside it', () => {
    expect(describe_(connection('tproxy/tproxy-in', '192.168.1.140'))).toEqual(
      expect.objectContaining({
        key: '192.168.1.140',
        name: 'POCO-F7',
        detail: '192.168.1.140',
      }),
    );
  });

  it('has only the address of a device nothing names', () => {
    expect(describe_(connection('tproxy/tproxy-in', '192.168.1.101'))).toEqual(
      expect.objectContaining({ name: '', detail: '192.168.1.101' }),
    );
  });

  it('calls the router itself System', () => {
    expect(label(connection('direct/system-in', '127.0.0.1'))).toBe('System');
    expect(label({ rule: 'inbound=system6-in => route(direct-out)' })).toBe(
      'System',
    );
  });

  it("calls the router's requests through a local proxy System", () => {
    expect(describe_(connection('mixed/service-warp-in', '127.0.0.1'))).toEqual(
      expect.objectContaining({ key: '@system', kind: 'system' }),
    );
    expect(label(connection('mixed/service-warp-in', '::1'))).toBe('System');
    expect(label(connection('socks/Open', '127.0.0.1'))).toBe('System');
  });

  it('lists the router, then named devices, then bare addresses', () => {
    const sources = [
      connection('tproxy/tproxy-in', '192.168.1.20'),
      connection('tproxy/tproxy-in', '192.168.1.101'),
      connection('tproxy/tproxy-in', '192.168.1.140'),
      connection('direct/system-in', '127.0.0.1'),
    ].map(describe_);

    expect(
      sources
        .sort(compareSources)
        .map((source) => sourceLabel(source.name, source.detail)),
    ).toEqual([
      'System',
      'POCO-F7 · 192.168.1.140',
      '192.168.1.20',
      '192.168.1.101',
    ]);
  });
});
