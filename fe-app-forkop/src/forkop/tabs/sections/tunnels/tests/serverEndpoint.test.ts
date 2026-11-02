import { beforeEach, expect, it } from 'vitest';

import { installLuciStubs } from '../../../../../helpers/tests/luciStubs';
import { validateTunnelSettings } from '../validate';

beforeEach(() => installLuciStubs());

it.each(['openvpn-server', ' OPENVPN-SERVER '])(
  'refuses a server endpoint in the client JSON tunnel editor: %s',
  (type) => {
    expect(
      validateTunnelSettings({
        tunnel_type: 'json',
        endpoint_json: JSON.stringify({
          type,
          tag: 'server',
          listen_port: 18443,
        }),
      }),
    ).toBe('VPN server endpoints are not supported');
  },
);

it.each(['openvpn-client', 'openconnect', 'wireguard'])(
  'keeps the client JSON endpoint path for %s',
  (type) => {
    expect(
      validateTunnelSettings({
        tunnel_type: 'json',
        endpoint_json: JSON.stringify({ type, tag: 'client' }),
      }),
    ).toBe(true);
  },
);
