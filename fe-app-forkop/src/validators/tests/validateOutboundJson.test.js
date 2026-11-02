import { describe, expect, it } from 'vitest';
import { validateOutboundJson } from '../validateOutboundJson';

describe('validateOutboundJson', () => {
  it.each([
    'wireguard',
    'amneziawg',
    'warp',
    'tailscale',
    'openvpn',
    'openvpn-client',
    'openvpn-server',
    'openconnect',
  ])('refuses retired %s even through a custom outbound', (type) => {
    for (const spelling of [type, ` ${type.toUpperCase()} `]) {
      const result = validateOutboundJson(
        JSON.stringify({
          type: spelling,
          tag: 'Retired',
          private_key: 'synthetic-private-key',
        }),
      );
      expect(result).toBe('VPN tunnel and server types are not supported');
      expect(result).not.toContain('synthetic-private-key');
    }
  });

  it('accepts a direct outbound with type and tag', () => {
    expect(validateOutboundJson('{"type":"direct","tag":"direct"}')).toBe(true);
  });

  it('accepts a server outbound with server and numeric server_port', () => {
    const result = validateOutboundJson(
      '{"type":"socks","tag":"proxy","server":"127.0.0.1","server_port":1080}',
    );

    expect(result).toBe(true);
  });

  it.each([
    '{"type":"a-type-from-a-newer-core","tag":"new"}',
    '{"type":"SOCKS","tag":"proxy"}',
    '{"type":"socks","tag":"proxy","server":"127.0.0.1"}',
    '{"type":"selector","tag":"select"}',
    '{"type":"socks","tag":"proxy","server_port":"1080","detour":""}',
    '{"tag":"typeless"}',
  ])('leaves the contents of %s to sing-box', (value) => {
    expect(validateOutboundJson(value)).toBe(true);
  });

  it('rejects empty input', () => {
    const result = validateOutboundJson('');

    expect(result).toBe('Required');
  });

  it('rejects text that is not JSON', () => {
    const result = validateOutboundJson('{"type":"direct",');

    expect(result).toBe('Invalid JSON object');
  });

  it('rejects arrays', () => {
    const result = validateOutboundJson('[{"type":"direct","tag":"direct"}]');

    expect(result).toBe('Invalid JSON object');
  });

  it.each(['{"type":"direct"}', '{"type":"direct","tag":"  "}', '{"tag":1}'])(
    'requires a non-empty tag field in %s',
    (value) => {
      const result = validateOutboundJson(value);

      expect(result).toBe('No tag field');
    },
  );

  it('rejects a tag already used by another JSON outbound', () => {
    const result = validateOutboundJson('{"type":"direct","tag":"duplicate"}', [
      'first',
      'duplicate',
    ]);

    expect(result).toBe('Name already taken');
  });
});
