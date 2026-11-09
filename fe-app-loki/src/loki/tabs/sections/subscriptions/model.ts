import { LOKI_UCI_PACKAGE } from '../../../../constants';
import { message } from '../../../../validators/messages';
import { validatePath } from '../../../../validators/validatePath';
import { validateUrl } from '../../../../validators/validateUrl';
import {
  applyChildItemSettings,
  childItemInputValue,
  getChildItemIds,
  isExistingChildItem,
} from '../../../cbi/childItems';
import { modalOptionFormValue } from '../../../cbi/modal';
import { E } from '../../../../helpers/element';
import { nextNumberedName } from '../../../../helpers/nextNumberedName';
import { executeShellCommand } from '../../../../helpers/executeShellCommand';
import { logger } from '../../../services/logger.service';
import { subscriptionOverrideKeys } from './overrides';

export let defaultSubscriptionHeaderLines: string[] = [];

let defaultSubscriptionHeadersPromise: Promise<string[]> | null = null;

export function loadDefaultSubscriptionHeaders() {
  if (defaultSubscriptionHeadersPromise) {
    return defaultSubscriptionHeadersPromise;
  }

  defaultSubscriptionHeadersPromise = executeShellCommand({
    command: '/usr/bin/loki',
    args: ['get_subscription_default_headers'],
  })
    .then((response) => {
      if (response.code) {
        throw new Error(
          response.stderr || _('Failed to load default subscription headers'),
        );
      }

      const parsed = JSON.parse(response.stdout || '[]');
      if (!Array.isArray(parsed)) {
        throw new Error(_('Failed to load default subscription headers'));
      }

      defaultSubscriptionHeaderLines = parsed
        .map((value: unknown) => `${value || ''}`.trim())
        .filter(Boolean);
      return defaultSubscriptionHeaderLines.slice();
    })
    .catch((error) => {
      defaultSubscriptionHeadersPromise = null;
      logger.error(
        'SECTIONS',
        'Failed to load default subscription headers',
        error,
      );
      throw error;
    });

  return defaultSubscriptionHeadersPromise;
}

export function optionMapValue(
  option: CBIOption,
  section_id: string,
  key: string,
) {
  const value =
    option && option.map && option.map.data
      ? option.map.data.get(option.map.config, section_id, key)
      : uci.get(LOKI_UCI_PACKAGE, section_id, key);

  return value == null ? '' : value;
}

// The widget's value once rendered, the stored one before, so a check sees a switch just turned on.
export function currentOptionValue(
  option: CBIOption,
  section_id: string,
  key: string,
) {
  const value = modalOptionFormValue(option.map, section_id, key);
  return value == null ? optionMapValue(option, section_id, key) : value;
}

function remoteSubscriptionUrlSettingsKeys() {
  return [
    'subscription_update_enabled',
    'subscription_update_interval',
    'download_via_proxy_enabled',
    'download_via_proxy_section',
    'header',
    'show_dashboard_metadata',
  ];
}

export function subscriptionUrlSettingsKeys() {
  return [
    ...remoteSubscriptionUrlSettingsKeys(),
    'tag',
    'detour_section',
    'server_filter_mode',
    'include_outbounds',
    'include_regex',
    'exclude_outbounds',
    'exclude_types',
    'exclude_regex',
    ...subscriptionOverrideKeys(),
  ];
}

// A local file that became a URL shows default fetch settings; defaults left alone are not written.
export function applyRemoteSubscriptionUrlSettings(
  itemId: string,
  settings: ChildSettings,
) {
  const remote: ChildSettings = {};
  remoteSubscriptionUrlSettingsKeys().forEach((key: string) => {
    remote[key] = settings[key];
  });
  applyChildItemSettings(itemId, remote);
}

export function cleanupRemoteSubscriptionUrlSettings(itemId: string) {
  remoteSubscriptionUrlSettingsKeys().forEach((key: string) =>
    uci.unset(LOKI_UCI_PACKAGE, itemId, key),
  );
}

// Only options the dialog shows or retains may be seeded: a hidden field without retain is removed
// on save.
export function defaultSubscriptionUrlSettings(
  headers: string[] = [],
  tag: string = 'sub1',
  remote: boolean = true,
) {
  const settings = {
    tag,
    server_filter_mode: 'all',
  };
  if (remote) {
    Object.assign(settings, {
      subscription_update_enabled: '1',
      subscription_update_interval: '1h',
      download_via_proxy_enabled: '0',
      header: Array.isArray(headers) ? headers.slice() : [],
      show_dashboard_metadata: '1',
    });
  }
  return settings;
}

// The live list's entries, so additions and removals count before the section is saved; an
// unrendered list answers nothing, and the stored children are used.
export function listedSubscriptionValues(
  sectionId: string,
  option: CBIOption,
): string[] {
  return (
    liveListValues(option, sectionId) ||
    getChildItemIds(sectionId, 'subscription_url')
  );
}

function liveListValues(option: CBIOption, sectionId: string) {
  let values: unknown = null;

  try {
    values = option && option.formvalue ? option.formvalue(sectionId) : null;
  } catch (_error) {
    return null;
  }

  return Array.isArray(values)
    ? values.map((value) => `${value || ''}`.trim()).filter(Boolean)
    : null;
}

// An address still in the add field is no entry yet and holds no tag.
export function listedSubscriptionTag(sectionId: string, value: string) {
  return isExistingChildItem(sectionId, value, 'subscription_url')
    ? `${uci.get(LOKI_UCI_PACKAGE, value, 'tag') || ''}`.trim()
    : '';
}

export function configuredSubscriptionTags(
  sectionId: string,
  option: CBIOption,
  excluded: string[] = [],
  values: string[] = listedSubscriptionValues(sectionId, option),
) {
  return values
    .filter((value) => !excluded.includes(value))
    .map((value) => listedSubscriptionTag(sectionId, value))
    .filter(Boolean);
}

export function nextSubscriptionTag(
  sectionId: string,
  option: CBIOption,
  values: string[] = listedSubscriptionValues(sectionId, option),
) {
  return nextNumberedName(
    'sub',
    configuredSubscriptionTags(sectionId, option, [], values),
    '',
  );
}

export function subscriptionListItemLabel(sectionId: string, value: string) {
  return E(
    'span',
    { class: 'fkp-dynlist-label' },
    listedSubscriptionTag(sectionId, value) ||
      childItemInputValue(sectionId, value, 'subscription_url', 'url'),
  );
}

function parseSubscriptionUrlEntry(
  value: unknown,
): { valid: true; url: string } | { valid: false; message: string } {
  const normalized = value ? `${value}`.trim() : '';

  if (!normalized.length) {
    return { valid: true, url: '' };
  }

  if (normalized.includes('|')) {
    return {
      valid: false,
      message: _('Set the User-Agent under Headers'),
    };
  }

  return { valid: true, url: normalized };
}

export function isRemoteSubscriptionSource(value: unknown) {
  const source = `${value || ''}`.trim();
  return source.startsWith('http://') || source.startsWith('https://');
}

export function validateSubscriptionUrlEntry(
  _section_id: string,
  value: string,
) {
  if (!value || value.length === 0) {
    return true;
  }

  const parsed = parseSubscriptionUrlEntry(value);
  if (!parsed.valid) {
    return parsed.message;
  }

  const validation = isRemoteSubscriptionSource(parsed.url)
    ? validateUrl(`${parsed.url}`)
    : validatePath(`${parsed.url}`);
  return validation === true ? true : message.urlOrPath();
}
