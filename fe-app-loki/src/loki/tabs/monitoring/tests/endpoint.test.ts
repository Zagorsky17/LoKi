import { describe, expect, it } from 'vitest';

import { formatEndpoint } from '../endpoint';

describe('the host a Monitoring row shows', () => {
  it('leaves out the ports of HTTP and HTTPS, as an address bar does', () => {
    expect(formatEndpoint('i.ytimg.com', 443)).toBe('i.ytimg.com');
    expect(formatEndpoint('i.ytimg.com', '443')).toBe('i.ytimg.com');
    expect(formatEndpoint('c.whatsapp.net', 80)).toBe('c.whatsapp.net');
    expect(formatEndpoint('fddb:33d1::1', '80')).toBe('fddb:33d1::1');
  });

  it('spells an international domain in its own letters', () => {
    expect(formatEndpoint('xn--d1abbgf6aiiy.xn--p1ai', 443)).toBe(
      'президент.рф',
    );
    expect(formatEndpoint('xn--e1afmkfd.xn--p1ai', 8443)).toBe(
      'пример.рф:8443',
    );
  });

  it('keeps a port that says what the connection is for', () => {
    expect(formatEndpoint('g.whatsapp.net', 5222)).toBe('g.whatsapp.net:5222');
    expect(formatEndpoint('149.154.167.50', '8443')).toBe(
      '149.154.167.50:8443',
    );
  });

  it('brackets an IPv6 address that carries a port', () => {
    expect(formatEndpoint('fddb:33d1::1', 5222)).toBe('[fddb:33d1::1]:5222');
    expect(formatEndpoint('fddb:33d1::1', 443)).toBe('fddb:33d1::1');
  });

  it('shows a dash for a connection with no destination', () => {
    expect(formatEndpoint('', 443)).toBe('-');
    expect(formatEndpoint(undefined, undefined)).toBe('-');
  });

  it('shows a host without a port as it is', () => {
    expect(formatEndpoint('i.ytimg.com', '')).toBe('i.ytimg.com');
  });
});
