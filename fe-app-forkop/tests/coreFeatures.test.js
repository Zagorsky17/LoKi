import { afterEach, describe, expect, it } from 'vitest';

import { coreFeatures, linkFeatureCases } from './lib/coreFeatures.js';
import {
  coreFeatureOfType,
  coreHas,
  coreSupportsType,
  linkCoreFeatures,
  missingCoreFeatureNote,
  missingCoreTags,
  setCoreFeatures,
  validateCoreFeature,
} from '../src/forkop/services/coreFeatures.service';
import { applyUiStateToStore } from '../src/forkop/services/uiState.service';
import {
  coreFilterTypeChoices,
  sectionMissingCoreFeatures,
} from '../src/forkop/tabs/sections/coreSupport';
import {
  groupTypeChoices,
  providerTypeChoices,
} from '../src/forkop/tabs/sections/providers';
import { installUciStub } from '../src/helpers/tests/luciStubs';

afterEach(() => setCoreFeatures(null));

describe('before the router has answered', () => {
  it('hides nothing, so the page offers what it always did', () => {
    expect(coreHas('quic')).toBe(true);
    expect(coreHas('naive')).toBe(true);
    expect(coreSupportsType('naive')).toBe(true);
    expect(linkCoreFeatures('hy2://p@example.com:443#h')).toEqual([]);
    expect(validateCoreFeature('naive')).toBe(true);
    expect(coreFilterTypeChoices(groupTypeChoices(), [])).toEqual(
      groupTypeChoices(),
    );
  });

  it('keeps hiding nothing for a router without a core', () => {
    setCoreFeatures({ ...coreFeatures(), known: false });
    expect(coreHas('clash_api')).toBe(true);
  });
});

describe('the base build', () => {
  it('has what it was built with and lacks the rest', () => {
    setCoreFeatures(coreFeatures());
    expect(coreHas('quic')).toBe(true);
    expect(coreHas('vmess')).toBe(true);
    expect(coreHas('naive')).toBe(false);
    expect(coreHas('ssh')).toBe(false);
  });

  it('looks outbound types up in the unchanged backend report', () => {
    setCoreFeatures(coreFeatures());
    expect(coreFeatureOfType('tuic')).toBe('quic');
    expect(coreSupportsType('ssh')).toBe(false);
    expect(coreSupportsType('naive')).toBe(false);
    expect(coreSupportsType('vless')).toBe(true);
  });

  it('names only the tags the build lacks', () => {
    setCoreFeatures(coreFeatures());
    expect(missingCoreTags('naive')).toEqual(['with_naive']);
    expect(missingCoreFeatureNote('naive')).toBe(
      'the installed sing-box lacks with_naive',
    );
    expect(validateCoreFeature('naive')).toBe(
      'sing-box is built without with_naive',
    );
    expect(validateCoreFeature('quic')).toBe(true);
    expect(validateCoreFeature('')).toBe(true);
  });
});

describe('a share link', () => {
  it.each(linkFeatureCases())('%s needs %j', (link, features) => {
    setCoreFeatures(coreFeatures());
    expect(linkCoreFeatures(link)).toEqual(features);
  });
});

describe('the runtime feed', () => {
  it('carries the report in, and a CLI answer without one leaves it', () => {
    const state = (core) => ({
      service: {
        forkop: { running: 1, enabled: 1, status: 'running', busy: null },
        sing_box: { running: 1, enabled: 1, status: 'running' },
      },
      capabilities: { core },
      actions: { service: [] },
    });

    applyUiStateToStore(state(coreFeatures({ remove: ['with_quic'] })));
    expect(coreHas('quic')).toBe(false);
    applyUiStateToStore(state());
    expect(coreHas('quic')).toBe(false);
    applyUiStateToStore(state(coreFeatures()));
    expect(coreHas('quic')).toBe(true);
  });
});

describe('the server types a filter offers', () => {
  it('are the ones the core can build, and the ones the filter already names', () => {
    setCoreFeatures(coreFeatures());
    const offered = coreFilterTypeChoices(providerTypeChoices(), ['naive']);

    expect(offered.map((choice) => choice.value)).toContain('hysteria2');
    expect(offered.find((choice) => choice.value === 'naive')?.label).toBe(
      'NaiveProxy (the installed sing-box lacks with_naive)',
    );
    const groupValues = coreFilterTypeChoices(groupTypeChoices(), []).map(
      (choice) => choice.value,
    );
    for (const missing of ['tailscale', 'openconnect', 'naive'])
      expect(groupValues).not.toContain(missing);
    expect(groupValues).toContain('direct');
  });
});

describe('what a section asks of the core', () => {
  it('uses its links and ignores retired tunnels and subscription contents', () => {
    setCoreFeatures(coreFeatures());
    installUciStub({
      sec: { '.type': 'section' },
      naive: {
        '.type': 'connection_link',
        section: 'sec',
        uri: 'naive+https://u:p@example.com:443#n',
      },
      reality: {
        '.type': 'connection_link',
        section: 'sec',
        uri: 'vless://u@example.com:443?security=reality&pbk=k#r',
      },
      tun: { '.type': 'tunnel', section: 'sec', kind: 'tailscale' },
      json: { '.type': 'tunnel', section: 'sec', kind: 'json' },
      sub: { '.type': 'subscription_url', section: 'sec', url: 'https://x' },
    });

    expect(sectionMissingCoreFeatures('sec').sort()).toEqual(['naive']);
  });
});

describe('retired tunnel tags and malformed links', () => {
  it.each([
    [],
    [
      'with_gvisor',
      'with_wireguard',
      'with_tailscale',
      'with_openvpn',
      'with_openconnect',
    ],
  ])('keeps outbound requirements with retired tags %j', (add) => {
    const value = coreFeatures({ add });
    setCoreFeatures(value);
    expect(Object.keys(value.types)).toEqual(['outbound']);
    expect(coreFeatureOfType('vmess')).toBe('vmess');
    expect(coreFeatureOfType('wireguard')).toBe('');
    expect(coreSupportsType('naive')).toBe(false);
    expect(
      linkCoreFeatures(
        'vless://u@example.com:443?security=reality&pbk=synthetic-key',
      ),
    ).toEqual(['utls']);
  });
  it('returns only protocol requirements for damaged VMess and no requirements for empty or unknown links', () => {
    setCoreFeatures(coreFeatures());
    for (const link of [
      '',
      ' ',
      'unknown://synthetic-secret',
      'without-a-scheme',
    ])
      expect(linkCoreFeatures(link)).toEqual([]);
    for (const link of ['vmess://broken%%%', 'vmess://e30='])
      expect(linkCoreFeatures(link)).toEqual(['vmess']);
  });
});

it('keeps an absent outbound table from a partial report from crashing the page', () => {
  for (const types of [{}, undefined]) {
    setCoreFeatures({ ...coreFeatures(), types });
    expect(coreFeatureOfType('vmess')).toBe('');
    expect(coreSupportsType('vmess')).toBe(true);
  }
});
