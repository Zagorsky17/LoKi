import { describe, expect, it } from 'vitest';

import { encodeTrustTunnelLink, trustTunnelLinkName } from '../trustTunnelLink';

// Written by TrustTunnel's own encoder, scripts/config_to_deeplink.py, as format version 2; the
// fields are the same in version 1, the one written here.
const REFERENCE =
  'tt://?AAEBAQ92cG4uZXhhbXBsZS5jb20FBWFsaWNlBglzZWNyZXQxMjMCCzEuMi4zLjQ6NDQzDArQntGE0LjRgSAx';

describe('TrustTunnel links', () => {
  it('writes the link TrustTunnel writes for the same settings', () => {
    expect(
      encodeTrustTunnelLink({
        hostname: 'vpn.example.com',
        address: '1.2.3.4:443',
        username: 'alice',
        password: 'secret123',
        name: 'Офис 1',
      }),
    ).toBe(REFERENCE);
  });

  it('reads back the name it writes, past a field longer than a one-byte length', () => {
    const link = encodeTrustTunnelLink({
      hostname: 'vpn.example.com',
      address: '1.2.3.4:443',
      username: 'alice',
      password: 'p'.repeat(400),
      skipVerification: true,
      http3: true,
      name: 'phone',
    });
    expect(link.slice('tt://?'.length)).not.toMatch(/[+/=]/);
    expect(trustTunnelLinkName(link.slice('tt://'.length))).toBe('phone');
  });
});
