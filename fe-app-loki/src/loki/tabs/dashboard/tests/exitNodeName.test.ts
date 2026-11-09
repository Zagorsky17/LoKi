import { describe, expect, it } from 'vitest';
import type { Loki } from '../../../types';
import { exitNodeName } from '../exitNodeName';

function outbound(
  code: string,
  displayName: string,
  extra: Partial<Loki.Outbound> = {},
): Loki.Outbound {
  return {
    code,
    displayName,
    latency: 0,
    type: 'VLESS',
    selected: false,
    ...extra,
  };
}

const section: Loki.OutboundGroup = {
  code: 'main-out',
  sectionName: 'main',
  displayName: 'Main',
  withTagSelect: true,
  outbounds: [
    outbound('main-1-out', '🇳🇱 Amsterdam'),
    outbound('main-urltest-out', 'Fastest', {
      selected: true,
      urlTestInfo: {
        code: 'main-urltest-out',
        displayName: 'Fastest',
        outbounds: [
          {
            code: 'main/sub1/🇫🇮 Helsinki',
            displayName: '🇫🇮 Helsinki',
            latency: 30,
            type: 'VLESS',
            selected: true,
          },
        ],
      },
    }),
  ],
};

describe('exitNodeName', () => {
  it('names the choice of a selector before any answer, and the single outbound of a plain section', () => {
    expect(exitNodeName(section)).toBe('Fastest');
    expect(
      exitNodeName({
        ...section,
        withTagSelect: false,
        outbounds: [outbound('vpn-out', 'Office')],
      }),
    ).toBe('Office');
  });

  it('finds the node an answer came through among the outbounds and their group members', () => {
    expect(exitNodeName(section, 'main-1-out')).toBe('🇳🇱 Amsterdam');
    expect(exitNodeName(section, 'main/sub1/🇫🇮 Helsinki')).toBe('🇫🇮 Helsinki');
    expect(exitNodeName(section, 'elsewhere-out')).toBe('elsewhere-out');
  });

  it('preserves a user-provided node name that contains the upstream product name', () => {
    const custom = {
      ...section,
      withTagSelect: false,
      outbounds: [outbound('remote-out', 'Loki remote node')],
    };
    expect(exitNodeName(custom)).toBe('Loki remote node');
    expect(exitNodeName(custom, 'remote-out')).toBe('Loki remote node');
  });
});
