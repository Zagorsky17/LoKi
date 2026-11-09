import { describe, expect, it } from 'vitest';

import { installLuciStubs, installUciStub } from './luciStubs';
import { analyzeStaticHosts } from '../../validators/validateStaticHosts';
import { validateOutboundJson } from '../../validators/validateOutboundJson';
import {
  DESTINATION_CONDITION_PLACEHOLDER,
  DOMAIN_CONDITION_PLACEHOLDER,
  analyzeDestinationText,
  analyzeDnsDestinationText,
} from '../../loki/tabs/sections/conditions';
import { JSON_OUTBOUND_PLACEHOLDER } from '../../loki/tabs/sections/outboundJson';
import { STATIC_HOSTS_PLACEHOLDER } from '../../loki/tabs/settings/staticHosts';
import {
  OVERRIDE_PATCH_PLACEHOLDER,
  reservedOverridePatchPath,
} from '../../loki/tabs/sections/subscriptions/overrides';

function loadSection() {
  installUciStub();
  return {
    DESTINATION_CONDITION_PLACEHOLDER,
    DOMAIN_CONDITION_PLACEHOLDER,
    JSON_OUTBOUND_PLACEHOLDER,
    OVERRIDE_PATCH_PLACEHOLDER,
    analyzeDestinationText,
    analyzeDnsDestinationText,
    reservedOverridePatchPath,
  };
}

function loadSettings() {
  installLuciStubs();
  return { STATIC_HOSTS_PLACEHOLDER };
}

describe('condition placeholders', () => {
  const section = loadSection();

  it.each([
    [
      'a routing',
      'DESTINATION_CONDITION_PLACEHOLDER',
      'analyzeDestinationText',
    ],
    ['a DNS', 'DOMAIN_CONDITION_PLACEHOLDER', 'analyzeDnsDestinationText'],
  ])(
    'offers %s section an example its field accepts',
    (_kind, name, analyzer) => {
      const analysis = section[analyzer](section[name]);

      expect(analysis.message).toBe('');
      expect(analysis.annotations).toEqual([]);
      expect(analysis.valid).toBe(true);
    },
  );

  it('shows every domain prefix the field understands', () => {
    for (const placeholder of [
      section.DESTINATION_CONDITION_PLACEHOLDER,
      section.DOMAIN_CONDITION_PLACEHOLDER,
    ]) {
      const prefixes = placeholder
        .split('\n')
        .map((line) => line.split(':')[0])
        .filter((prefix) => ['full', 'keyword', 'regex'].includes(prefix));

      expect(prefixes.sort()).toEqual(['full', 'keyword', 'regex']);
    }
  });

  it('shows a routing section a bare address, an IPv4 subnet and an IPv6 subnet', () => {
    expect(
      section.DESTINATION_CONDITION_PLACEHOLDER.split('\n').slice(-3),
    ).toEqual([
      expect.not.stringContaining('/'),
      expect.stringMatching(/^\d+\.\d+\.\d+\.\d+\/\d+$/),
      expect.stringMatching(/^[0-9a-f:]+\/\d+$/),
    ]);
  });
});

describe('JSON placeholders', () => {
  const section = loadSection();

  it('offers a JSON outbound the outbound validator accepts', () => {
    expect(validateOutboundJson(section.JSON_OUTBOUND_PLACEHOLDER)).toBe(true);
  });

  it('offers a server-parameters patch the field does not refuse', () => {
    const patch = JSON.parse(section.OVERRIDE_PATCH_PLACEHOLDER);

    expect(section.reservedOverridePatchPath(patch)).toBeUndefined();
  });
});

describe('static DNS records placeholder', () => {
  it('offers records the hosts analyzer accepts', () => {
    const settings = loadSettings();
    const analysis = analyzeStaticHosts(settings.STATIC_HOSTS_PLACEHOLDER);

    expect(analysis.message).toBe('');
    expect(analysis.valid).toBe(true);
  });
});
