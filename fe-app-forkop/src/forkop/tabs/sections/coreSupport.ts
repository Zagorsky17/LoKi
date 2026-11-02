import { FORKOP_UCI_PACKAGE } from '../../../constants';
import {
  coreFeatureOfType,
  coreHas,
  coreSupportsType,
  linkCoreFeatures,
  missingCoreFeatureNote,
  validateCoreFeature,
} from '../../services/coreFeatures.service';

// The share links a section dials itself, by name, and the sing-box type the
// name stands for in the installed core.
const CONNECTION_URI_TYPES = [
  ['vless', 'vless'],
  ['vmess', 'vmess'],
  ['shadowsocks', 'shadowsocks'],
  ['trojan', 'trojan'],
  ['socks', 'socks'],
  ['http', 'http'],
  ['tuic', 'tuic'],
  ['hysteria', 'hysteria2'],
  ['naiveproxy', 'naive'],
  ['mieru', 'mieru'],
  ['anytls', 'anytls'],
  ['trusttunnel', 'trusttunnel'],
];

export function connectionUriDescription() {
  return _('Supported URIs: %s').format(
    CONNECTION_URI_TYPES.filter(([, type]) => coreSupportsType(type))
      .map(([name]) => name)
      .join(', '),
  );
}

// A link the installed core would fail to start with: its protocol, or the uTLS hello a
// fingerprint or Reality asks for, is not in the build.
export function validateConnectionUriCore(link: string) {
  return validateCoreFeature(
    linkCoreFeatures(link).find((feature) => !coreHas(feature)) || '',
  );
}

// Subscriptions are not included: the core skips a server it cannot build and starts anyway.
export function sectionMissingCoreFeatures(sectionId: string) {
  const missing = new Set<string>();
  (uci.sections(FORKOP_UCI_PACKAGE, 'connection_link') || [])
    .filter((link) => link.section === sectionId)
    .forEach((link) =>
      linkCoreFeatures(`${link.uri || ''}`)
        .filter((feature) => !coreHas(feature))
        .forEach((feature) => missing.add(feature)),
    );
  return [...missing];
}

// Types the installed core can build, plus any the filter already names, so a save keeps them.
export function coreFilterTypeChoices(
  choices: Array<{ value: string; label: string }>,
  selected: string[],
) {
  return choices
    .filter(
      (choice) =>
        coreSupportsType(choice.value) || selected.includes(choice.value),
    )
    .map((choice) =>
      coreSupportsType(choice.value)
        ? choice
        : {
            value: choice.value,
            label: `${choice.label} (${missingCoreFeatureNote(coreFeatureOfType(choice.value))})`,
          },
    );
}
