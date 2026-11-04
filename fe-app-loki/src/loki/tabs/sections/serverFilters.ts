import { refreshOptionChoices } from '../../cbi/choices';
import {
  normalizeDynamicListItems,
  normalizeOptionValues,
} from '../../cbi/listValues';
import { modalOptionFormValue } from '../../cbi/modal';
import {
  configureLiveDynamicListChoices,
  currentOutboundNameChoices,
  currentSubscriptionOutboundNameChoices,
} from './outboundNames';
import { coreFilterTypeChoices } from './coreSupport';
import { groupTypeChoices, providerTypeChoices } from './providers';
import { optionMapValue } from './subscriptions/model';
import { validateRegex } from './validators';

// A mode, a server list and a pattern, shared by subscriptions, URLTests and Fallback groups.
interface ServerFilterOptions {
  modes?: Array<{ value: string; label: string }>;
  modeLabel?: string;
  modeDescription?: string;
  defaultMode?: string;
  // The choices are the kinds of group rather than the kinds of provider.
  groupContext?: boolean;
  // The subscription an outbound name belongs to, for a filter inside one.
  ownerId?: () => string;
  excludeTypesDescription?: string;
  excludeRegexDescription?: string;
  includeRegexDescription?: string;
  includeServersDescription?: string;
  blacklistExcludeServersDescription?: string;
  whitelistExcludeServersDescription?: string;
}

// The fields two modes share, so switching mode keeps what was already typed.
type SharedFilterFields = Record<string, Record<string, CBIOption>>;

// One filter field: the name the form knows it by, the uci option it is stored
// under, its wording, what checks it, and the modes it is shown in.
type FilterFieldSpec = [
  key: string,
  storageKey: string,
  label: string,
  description: string | undefined,
  validator: ((value: string) => string | true) | null,
  visibleModes: string[],
];

export function syncServerFilterFields(
  sharedFields: SharedFilterFields,
  sourceMode: string,
  itemId: string,
) {
  const sourceFields = sharedFields[sourceMode];
  if (!sourceFields) {
    return;
  }

  Object.entries(sourceFields).forEach(([storageKey, sourceField]) => {
    const sourceElement = sourceField.getUIElement(itemId);
    if (!sourceElement || typeof sourceElement.getValue !== 'function') {
      return;
    }
    Object.values(sharedFields).forEach((fields) => {
      const targetElement = fields[storageKey]?.getUIElement(itemId);
      if (targetElement && typeof targetElement.setValue === 'function') {
        targetElement.setValue(sourceElement.getValue());
      }
    });
  });
}

// Shared by the three filter blocks; only the lines naming where the servers end up differ.
function sharedServerFilterDescriptions() {
  return {
    includeRegexDescription: _(
      'Servers whose names match the regular expression',
    ),
    excludeRegexDescription: _(
      'Remove servers whose names match the regular expression',
    ),
    whitelistExcludeServersDescription: _(
      'Remove servers from the selection above',
    ),
  };
}

export function groupServerFilterDescriptions() {
  return Object.assign(sharedServerFilterDescriptions(), {
    includeServersDescription: _('The servers that end up in the group'),
    blacklistExcludeServersDescription: _(
      'The servers that do not end up in the group',
    ),
    excludeTypesDescription: _(
      'Servers of these protocols do not end up in the group',
    ),
  });
}

export function subscriptionServerFilterDescriptions() {
  return Object.assign(sharedServerFilterDescriptions(), {
    includeServersDescription: _('The servers that are imported'),
    blacklistExcludeServersDescription: _('The servers that are not imported'),
    excludeTypesDescription: _('Servers of these protocols are not imported'),
  });
}

// "Only selected" naming no server keeps none: the group's include pattern matches nothing, so it
// is dropped without a provider and stays empty with one. A Fallback level counts the URLTest it
// includes as a member.
export function missingFilterSelectionMessage(
  modeOption: CBIOption,
  itemId: string,
) {
  if (modeOption.formvalue(itemId) !== 'include') {
    return null;
  }

  return ['include_outbounds', 'include_regex', 'include_groups'].some(
    (optionName: string) =>
      normalizeDynamicListItems(
        modalOptionFormValue(modeOption.map, itemId, optionName),
      ).length > 0,
  )
    ? null
    : _('Select a server or set a pattern');
}

export function addServerFilterOptions(
  itemSection: CBISection,
  parentSectionForItem: (itemId: string) => string,
  options: ServerFilterOptions = {},
) {
  const modes = Array.isArray(options.modes) ? options.modes : [];
  const o = itemSection.option(
    form.ListValue,
    'server_filter_mode',
    options.modeLabel,
    options.modeDescription,
  );
  modes.forEach((mode) => o.value(mode.value, mode.label));
  o.default = options.defaultMode || 'all';
  o.rmempty = false;

  const modeOption = o;
  const sharedFields: SharedFilterFields = {};
  (
    [
      [
        'include_outbounds',
        'include_outbounds',
        _('Include servers'),
        options.includeServersDescription,
        null,
        ['include'],
      ],
      [
        'include_regex',
        'include_regex',
        _('Include by pattern'),
        options.includeRegexDescription,
        validateRegex,
        ['include'],
      ],
      [
        '_blacklist_exclude_outbounds',
        'exclude_outbounds',
        _('Exclude servers'),
        options.blacklistExcludeServersDescription,
        null,
        ['exclude'],
      ],
      [
        '_blacklist_exclude_types',
        'exclude_types',
        _('Exclude types'),
        options.excludeTypesDescription,
        null,
        ['exclude'],
      ],
      [
        '_blacklist_exclude_regex',
        'exclude_regex',
        _('Exclude by pattern'),
        options.excludeRegexDescription,
        validateRegex,
        ['exclude'],
      ],
      [
        '_whitelist_exclude_outbounds',
        'exclude_outbounds',
        _('Exclude servers'),
        options.whitelistExcludeServersDescription,
        null,
        ['include'],
      ],
      [
        '_whitelist_exclude_types',
        'exclude_types',
        _('Exclude types'),
        options.excludeTypesDescription,
        null,
        ['include'],
      ],
      [
        '_whitelist_exclude_regex',
        'exclude_regex',
        _('Exclude by pattern'),
        options.excludeRegexDescription,
        validateRegex,
        ['include'],
      ],
    ] as FilterFieldSpec[]
  ).forEach(
    ([key, storageKey, label, description, validator, visibleModes]) => {
      const isList =
        storageKey.endsWith('_outbounds') || storageKey === 'exclude_types';
      const field = itemSection.option(
        isList ? form.DynamicList : form.Value,
        key,
        label,
        description,
      );
      (visibleModes || []).forEach((mode) =>
        field.depends('server_filter_mode', mode),
      );
      field.rmempty = true;
      if (key !== storageKey) {
        field.ucioption = storageKey;
        field.retain = true;
        const mode = (visibleModes || [])[0];
        if (mode) {
          if (!sharedFields[mode]) {
            sharedFields[mode] = {};
          }
          sharedFields[mode][storageKey] = field;
        }
      }
      if (storageKey === 'exclude_types') {
        const choices = options.groupContext
          ? groupTypeChoices()
          : providerTypeChoices();
        field.load = function (itemId: string) {
          const values = normalizeOptionValues(
            optionMapValue(this, itemId, storageKey),
          );
          refreshOptionChoices(this, coreFilterTypeChoices(choices, values));
          return values;
        };
        field.placeholder = _('-- Select --');
      }
      if (storageKey.endsWith('_outbounds')) {
        field.load = function (itemId: string) {
          return normalizeOptionValues(
            optionMapValue(this, itemId, storageKey),
          );
        };
        field.placeholder = _('-- Select --');
        configureLiveDynamicListChoices(
          field,
          (itemId: string) =>
            typeof options.ownerId === 'function'
              ? currentSubscriptionOutboundNameChoices(
                  parentSectionForItem(itemId),
                  options.ownerId(),
                )
              : currentOutboundNameChoices(parentSectionForItem(itemId)),
          parentSectionForItem,
        );
      }
      if (validator) {
        field.validate = function (_itemId: string, value: string) {
          return validator(value);
        };
      }
    },
  );

  const modeOptionParse = modeOption.parse;
  modeOption.parse = function (itemId: string) {
    const message = missingFilterSelectionMessage(this, itemId);
    if (message) {
      return Promise.reject(new TypeError(message));
    }

    return modeOptionParse.call(this, itemId);
  };

  let activeMode: unknown =
    optionMapValue(modeOption, 'settings', 'server_filter_mode') ||
    modeOption.default;
  modeOption.onchange = function (
    _event: Event,
    itemId: string,
    value: unknown,
  ) {
    syncServerFilterFields(sharedFields, `${activeMode ?? ''}`, itemId);
    activeMode = value;
  };
}
