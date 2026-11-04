import { afterEach, describe, expect, it, vi } from 'vitest';

import { buildLocalDevices } from '../localDevices';

afterEach(() => {
  vi.unstubAllGlobals();
});

const hostHints = {
  '02:00:00:00:00:01': {
    ipaddrs: ['192.168.1.1'],
    ip6addrs: ['fe80::1'],
    name: 'OpenWrt.lan',
  },
  '02:00:00:00:00:10': {
    ipaddrs: ['192.168.1.140'],
    ip6addrs: [],
    name: 'PC.lan',
  },
  '02:00:00:00:00:11': {
    ipaddrs: ['192.168.1.144'],
    ip6addrs: ['2001:db8:1::11', 'fe80::11'],
    name: 'Phone.lan',
  },
  '02:00:00:00:00:12': {
    ipaddrs: ['192.168.1.101'],
    ip6addrs: ['2001:db8:1::12'],
  },
  '02:00:00:00:00:13': {
    ipaddrs: [],
    ip6addrs: ['2001:db8:1::13'],
  },
  '02:00:00:00:00:20': {
    ipaddrs: ['100.64.0.1'],
    ip6addrs: ['fe80::20'],
  },
  '02:00:00:00:00:21': {
    ipaddrs: ['100.64.10.20'],
    ip6addrs: ['fe80::21'],
  },
};

const dhcpLeases = {
  dhcp_leases: [
    { hostname: 'PC', macaddr: '02:00:00:00:00:10', ipaddr: '192.168.1.140' },
    {
      hostname: 'Phone',
      macaddr: '02:00:00:00:00:11',
      ipaddr: '192.168.1.144',
    },
    { macaddr: '02:00:00:00:00:12', ipaddr: '192.168.1.101' },
  ],
  dhcp6_leases: [],
};

const networkInterfaces = [
  {
    interface: 'lan',
    'ipv4-address': [{ address: '192.168.1.1', mask: 24 }],
    'ipv6-address': [{ address: '2001:db8:1::1', mask: 64 }],
  },
  {
    interface: 'wan',
    'ipv4-address': [{ address: '100.64.10.20', mask: 10 }],
    'ipv6-address': [],
  },
];

const staticHosts = [
  { name: 'nas', ip: '192.168.1.10', mac: '02:00:00:00:00:30' },
  { ip: '192.168.1.11', mac: '02:00:00:00:00:31' },
];

describe('the devices the picker offers', () => {
  it('names each device the router knows by its name', () => {
    const { choices } = buildLocalDevices(
      hostHints,
      dhcpLeases,
      networkInterfaces,
      staticHosts,
    );

    expect(choices['192.168.1.140']).toBe('PC');
    expect(choices['192.168.1.144']).toBe('Phone');
    expect(choices['192.168.1.10']).toBe('nas');
  });

  it('offers the router itself once, as System', () => {
    const { choices } = buildLocalDevices(
      hostHints,
      dhcpLeases,
      networkInterfaces,
      staticHosts,
    );

    expect(choices['@system']).toBe('System');
    expect(choices).not.toHaveProperty('192.168.1.1');
    expect(choices).not.toHaveProperty('100.64.10.20');
  });

  it('takes the name of a static host over the one its lease reports', () => {
    const { choices } = buildLocalDevices(
      {},
      {
        dhcp_leases: [
          {
            hostname: 'android-1f3a',
            macaddr: '02:00:00:00:00:40',
            ipaddr: '192.168.1.50',
          },
        ],
      },
      [],
      [{ name: 'tv', ip: '192.168.1.50', mac: '02:00:00:00:00:40' }],
    );

    expect(choices['192.168.1.50']).toBe('tv');
  });

  it('tells a device named system apart from the router', () => {
    const { choices } = buildLocalDevices(
      {},
      {
        dhcp_leases: [
          {
            hostname: 'system',
            macaddr: '02:00:00:00:00:41',
            ipaddr: '192.168.1.51',
          },
        ],
      },
      [],
      [],
    );

    expect(choices['192.168.1.51']).toBe('system (192.168.1.51)');
  });

  it('compares a name with the router entry as the page shows it', () => {
    vi.stubGlobal('_', (key: string) => (key === 'System' ? 'Система' : key));
    const { choices } = buildLocalDevices(
      {},
      { dhcp_leases: [] },
      [],
      [
        { name: 'Система', ip: '192.168.1.53', mac: '02:00:00:00:00:44' },
        { name: 'system', ip: '192.168.1.54', mac: '02:00:00:00:00:45' },
      ],
    );

    expect(choices['@system']).toBe('Система');
    expect(choices['192.168.1.53']).toBe('Система (192.168.1.53)');
    expect(choices['192.168.1.54']).toBe('system');
  });

  it('tells apart two addresses the router knows by one name', () => {
    const { choices } = buildLocalDevices(
      {
        '02:00:00:00:00:10': {
          ipaddrs: ['192.168.1.140', '192.168.1.141'],
          name: 'PC.lan',
        },
      },
      { dhcp_leases: [] },
      [],
      [],
    );

    expect(choices['192.168.1.140']).toBe('PC (192.168.1.140)');
    expect(choices['192.168.1.141']).toBe('PC (192.168.1.141)');
  });

  it('skips an address that is not one', () => {
    const { choices } = buildLocalDevices(
      {},
      {
        dhcp_leases: [
          {
            hostname: 'odd',
            macaddr: '02:00:00:00:00:42',
            ipaddr: '192.168.1.300',
          },
        ],
      },
      [],
      [],
    );

    expect(Object.values(choices)).not.toContain('odd');
  });

  it('offers a leased device without a name by its address', () => {
    const { choices } = buildLocalDevices(
      hostHints,
      dhcpLeases,
      networkInterfaces,
      staticHosts,
    );

    expect(choices['192.168.1.101']).toBe('192.168.1.101 (02:00:00:00:00:12)');
    expect(choices['192.168.1.11']).toBe('192.168.1.11 (02:00:00:00:00:31)');
  });

  it('leaves out a neighbour nothing places on the local network', () => {
    const { choices } = buildLocalDevices(
      hostHints,
      dhcpLeases,
      networkInterfaces,
      staticHosts,
    );

    expect(choices).not.toHaveProperty('100.64.0.1');
  });

  it('offers no IPv6 address, which a device changes by itself', () => {
    const { choices } = buildLocalDevices(
      hostHints,
      dhcpLeases,
      networkInterfaces,
      staticHosts,
    );

    expect(Object.keys(choices).filter((value) => value.includes(':'))).toEqual(
      [],
    );
  });

  it('keeps the name a hint gives an address its lease leaves unnamed', () => {
    const { choices } = buildLocalDevices(
      {
        '02:00:00:00:00:43': { ipaddrs: ['192.168.1.52'], name: 'printer.lan' },
      },
      {
        dhcp_leases: [{ macaddr: '02:00:00:00:00:43', ipaddr: '192.168.1.52' }],
      },
      [],
      [],
    );

    expect(choices['192.168.1.52']).toBe('printer');
  });

  it('lists the router, then named devices, then bare addresses in order', () => {
    const { order } = buildLocalDevices(
      hostHints,
      dhcpLeases,
      networkInterfaces,
      staticHosts,
    );

    expect(order).toEqual([
      '@system',
      '192.168.1.10',
      '192.168.1.140',
      '192.168.1.144',
      '192.168.1.11',
      '192.168.1.101',
    ]);
  });
});

describe('the names monitoring puts to a source address', () => {
  it('holds only devices that have a name', () => {
    const { names } = buildLocalDevices(
      hostHints,
      dhcpLeases,
      networkInterfaces,
      staticHosts,
    );

    expect(names).toMatchObject({
      '192.168.1.10': 'nas',
      '192.168.1.140': 'PC',
      '192.168.1.144': 'Phone',
    });
    ['192.168.1.101', '192.168.1.11', '2001:db8:1::12', '100.64.0.1'].forEach(
      (address) => expect(names).not.toHaveProperty(address),
    );
  });

  it('names a device by its IPv6 addresses too', () => {
    const { names } = buildLocalDevices(
      hostHints,
      dhcpLeases,
      networkInterfaces,
      staticHosts,
    );

    expect(names['2001:db8:1::11']).toBe('Phone');
    expect(names['fe80::11']).toBe('Phone');
  });
});
