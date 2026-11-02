import { FORKOP_UCI_PACKAGE } from '../../../constants';
import { getProxyUrlName } from '../../../helpers/getProxyUrlName';
import { nextNumberedName } from '../../../helpers/nextNumberedName';
import { message } from '../../../validators/messages';
import {
  childItemInputValue,
  getChildItemIds,
  isExistingChildItem,
} from '../../cbi/childItems';
import { refreshOptionChoices } from '../../cbi/choices';
import { childPendingSettingsStore } from '../../cbi/itemSettings';
import { validateUniqueDynamicListItemName } from '../../cbi/listItems';
import {
  normalizeDynamicListItems,
  normalizeOptionValues,
} from '../../cbi/listValues';
import { getConfigListValues, plainObject } from '../../cbi/uci';
import {
  outboundJsonDisplayTag,
  parseOutboundJsonObject,
} from './outboundJson';
import { optionMapValue } from './subscriptions/model';
import { getClashApiProxyProviders } from '../../methods/custom/clashApi';

interface ProviderServerNames {
  imported: string[];
  // What the subscription's own filter chooses from, those it drops included.
  filterCandidates: string[];
}

type ProviderServerNameKind = keyof ProviderServerNames;

let providerServerNames: Map<string, ProviderServerNames> | null = null;
let providerServerNamesAt = 0;
let providerServerNamesInflight: Promise<void> | null = null;

// A subscription has servers only once the core fetched it, so an answer lacking one expires.
const PROVIDER_SERVER_NAMES_RETRY_MS = 5000;

// Each dialog asks again: a subscription that updated meanwhile delivers other servers.
export function forgetOutboundNameChoices() {
  providerServerNames = null;
  providerServerNamesAt = 0;
}

export const outboundNameSourceOptions = new Map();

const liveChoiceRefreshers = new Map<string, Set<() => boolean | void>>();

// The groups the core builds out of a subscription are no servers of it.
export function providerServerNameMap(value: unknown) {
  const result = new Map<string, ProviderServerNames>();

  Object.entries(plainObject(plainObject(value).providers)).forEach(
    ([providerTag, provider]) => {
      const { proxies, filterCandidates } = plainObject(provider);
      const runtimePrefix = `${providerTag}/`;
      const names: string[] = [];

      (Array.isArray(proxies) ? proxies : []).forEach((proxy) => {
        proxy = plainObject(proxy);
        const type = `${proxy.type || ''}`.toLowerCase();
        if (['selector', 'urltest', 'fallback'].includes(type)) {
          return;
        }

        let name = `${proxy.name || ''}`.trim();
        if (name.startsWith(runtimePrefix)) {
          name = name.slice(runtimePrefix.length);
        }
        if (name) {
          names.push(name);
        }
      });
      result.set(providerTag, {
        imported: names,
        filterCandidates: (Array.isArray(filterCandidates)
          ? filterCandidates
          : []
        )
          .map((name) => `${name || ''}`.trim())
          .filter(Boolean),
      });
    },
  );

  return result;
}

export function loadProviderServerNames(): Promise<void> {
  if (providerServerNamesInflight) {
    return providerServerNamesInflight;
  }

  providerServerNamesInflight = getClashApiProxyProviders()
    .then((response) =>
      response.success
        ? providerServerNameMap(response.data)
        : new Map<string, ProviderServerNames>(),
    )
    .catch(() => new Map<string, ProviderServerNames>())
    .then((names) => {
      providerServerNames = names;
      providerServerNamesAt = Date.now();
      refreshAllLiveChoiceWidgets();
    })
    .finally(() => {
      providerServerNamesInflight = null;
    });

  return providerServerNamesInflight;
}

// The core runs a subscription as "<section label>/<subscription tag>" by the names uci.js loaded.
function subscriptionProviderTag(section_id: string, itemId: string) {
  const loaded = uci.state.values[FORKOP_UCI_PACKAGE] || {};
  if (
    !loaded[itemId] ||
    !isExistingChildItem(section_id, itemId, 'subscription_url')
  ) {
    return '';
  }

  const tag = `${loaded[itemId].tag || ''}`.trim();
  const label = `${loaded[section_id]?.label || section_id}`.trim();
  return tag ? `${label}/${tag}` : '';
}

function subscriptionServerNames(
  section_id: string,
  itemIds: string[],
  kind: ProviderServerNameKind,
) {
  const providerTags = itemIds
    .map((itemId) => subscriptionProviderTag(section_id, itemId))
    .filter(Boolean);

  if (
    providerTags.some((tag) => !providerServerNames?.get(tag)?.[kind].length) &&
    Date.now() - providerServerNamesAt >= PROVIDER_SERVER_NAMES_RETRY_MS
  ) {
    void loadProviderServerNames();
  }

  return providerTags.flatMap(
    (tag) => providerServerNames?.get(tag)?.[kind] || [],
  );
}

export function configureLiveDynamicListChoices(
  option: CBIOption,
  getChoices: (sectionId: string) => Array<{ value: string; label: string }>,
  getRefreshSectionId = (section_id: string) => section_id,
) {
  option.renderWidget = function (
    section_id: string,
    _option_index: string,
    cfgvalue: unknown,
  ) {
    const refreshSectionId =
      `${getRefreshSectionId(section_id) || section_id}`.trim();
    const values = L.toArray(cfgvalue != null ? cfgvalue : this.default);
    const choices = getChoices(section_id);
    const labels: Record<string, string> = {};
    choices.forEach((choice) => {
      labels[choice.value] = choice.label;
    });
    refreshOptionChoices(this, choices);
    let choiceSignature = JSON.stringify(
      choices.map((choice) => [choice.value, choice.label]),
    );
    // form.DynamicList renders a plain input for good when given null; an empty object keeps the
    // combobox, so live choices can be added later.
    const widget = new ui.DynamicList(values, labels, {
      id: this.cbid(section_id),
      sort: this.keylist,
      allowduplicates: this.allowduplicates,
      optional: this.optional || this.rmempty,
      datatype: this.datatype,
      placeholder: this.placeholder,
      validate: L.bind(this.validate, this, section_id),
      disabled: this.readonly != null ? this.readonly : this.map.readonly,
    });
    const node = widget.render();
    const refreshChoices = () => {
      if (!node.isConnected) {
        return false;
      }

      const currentChoices = getChoices(section_id);
      const currentLabels: Record<string, string> = {};
      currentChoices.forEach((choice) => {
        currentLabels[choice.value] = choice.label;
      });
      const currentSignature = JSON.stringify(
        currentChoices.map((choice) => [choice.value, choice.label]),
      );

      if (currentSignature === choiceSignature) {
        return;
      }
      choiceSignature = currentSignature;

      refreshOptionChoices(this, currentChoices);
      widget.choices = currentLabels;
      widget.clearChoices();
      widget.addChoices(
        currentChoices.map((choice) => choice.value),
        currentLabels,
      );
      return true;
    };
    const refreshBeforeOpening = (event: Event) => {
      if (event.target && (event.target as Element).closest('.add-item')) {
        refreshChoices();
      }
    };
    node.addEventListener('mousedown', refreshBeforeOpening, true);
    node.addEventListener('focusin', refreshBeforeOpening, true);

    if (!liveChoiceRefreshers.has(refreshSectionId)) {
      liveChoiceRefreshers.set(refreshSectionId, new Set());
    }
    liveChoiceRefreshers.get(refreshSectionId)!.add(refreshChoices);

    return node;
  };
}

export function outboundNameChoiceItems(names: string[]) {
  return Array.from(
    new Set(names.map((name) => `${name || ''}`.trim()).filter(Boolean)),
    (value) => ({ value, label: value }),
  );
}

// As the dashboard lists them: the section's own servers, then each subscription's in turn.
export function currentOutboundNameChoices(section_id: string) {
  return outboundNameChoiceItems([
    ...currentDraftOutboundNames(section_id),
    ...subscriptionServerNames(
      section_id,
      currentSourceOptionValues(section_id, 'subscription_url'),
      'imported',
    ),
  ]);
}

export function currentSubscriptionOutboundNameChoices(
  section_id: string,
  itemId: string,
) {
  return outboundNameChoiceItems(
    subscriptionServerNames(section_id, [itemId], 'filterCandidates'),
  );
}

function currentSourceOptionValues(section_id: string, optionName: string) {
  const liveValues = currentLiveDynamicListValues(section_id, optionName);
  if (liveValues != null) {
    return liveValues;
  }

  const option = outboundNameSourceOptions.get(optionName);

  if (option && typeof option.formvalue === 'function') {
    try {
      const value = option.formvalue(section_id);
      if (value != null) {
        return normalizeDynamicListItems(value);
      }
    } catch (_error) {
      // Fall back to the LuCI UCI cache when the section widget is not mounted.
    }
  }

  // A list of child sections stores its entries as those sections, not as an
  // option of the section.
  return option?.childType
    ? getChildItemIds(section_id, option.childType)
    : getConfigListValues(section_id, optionName);
}

export function currentLiveDynamicListValues(
  section_id: string,
  optionName: string,
) {
  if (typeof document === 'undefined') {
    return null;
  }

  const option = outboundNameSourceOptions.get(optionName);
  const trackedWidget = option?.liveDynamicListNodes?.get(section_id);
  let widget;

  if (trackedWidget) {
    if (trackedWidget.isConnected === false) {
      return null;
    }
    widget = trackedWidget;
  } else {
    widget = document.getElementById(
      `cbid.${FORKOP_UCI_PACKAGE}.${section_id}.${optionName}`,
    );
  }

  if (!widget) {
    return null;
  }

  const values = Array.from(
    widget.querySelectorAll('.item > input[type="hidden"]'),
  )
    .map((input) => `${(input as HTMLInputElement).value || ''}`.trim())
    .filter(Boolean);
  const pendingInput = widget.querySelector(
    '.add-item > input[type="text"]',
  ) as HTMLInputElement | null;
  const pendingValue = `${(pendingInput && pendingInput.value) || ''}`.trim();

  if (
    pendingValue &&
    !pendingInput!.classList.contains('cbi-input-invalid') &&
    !values.includes(pendingValue)
  ) {
    values.push(pendingValue);
  }

  return values;
}

export type SectionChildKind =
  | 'link'
  | 'interface'
  | 'json'
  | 'urltest'
  | 'fallback';

const GROUP_OUTBOUND_TYPES = [
  'selector',
  'urltest',
  'fallback',
  'dns',
  'block',
];

// As the section form holds them now, unsaved additions and removals included.
function currentGroupNames(
  section_id: string,
  optionName: string,
  typeName: string,
) {
  const listOption = outboundNameSourceOptions.get(optionName);
  const store = listOption
    ? childPendingSettingsStore(listOption, section_id)
    : {};

  return currentSourceOptionValues(section_id, optionName)
    .map((value: unknown) => {
      const itemValue = `${value || ''}`.trim();
      return itemValue
        ? `${
            store[itemValue]?.name ||
            childItemInputValue(section_id, itemValue, typeName, 'name') ||
            itemValue
          }`.trim()
        : '';
    })
    .filter(Boolean);
}

// Each runs as "<section>/<name>"; a member is one a URLTest or a Fallback level can pick, and an
// interface keeps its own name as its value.
export function sectionChildNames(section_id: string) {
  const result: Array<{
    kind: SectionChildKind;
    name: string;
    member: boolean;
    value: string;
  }> = [];
  const add = (
    kind: SectionChildKind,
    name: unknown,
    member = true,
    value = '',
  ) => {
    const normalized = `${name || ''}`.trim();
    if (normalized) {
      result.push({ kind, name: normalized, member, value });
    }
  };

  currentSourceOptionValues(section_id, 'connection_link').forEach(
    (value: string, index: number) =>
      add(
        'link',
        (isExistingChildItem(section_id, value, 'connection_link')
          ? uci.get(FORKOP_UCI_PACKAGE, value, 'name')
          : '') ||
          getProxyUrlName(value) ||
          `Node #${index + 1}`,
      ),
  );
  currentSourceOptionValues(section_id, 'interfaces').forEach(
    (itemId: string) => {
      const interfaceName = childItemInputValue(
        section_id,
        itemId,
        'section_interface',
        'name',
      ).trim();
      const option = outboundNameSourceOptions.get('interfaces');
      const staged = childPendingSettingsStore(option, section_id)[
        interfaceName
      ];
      add(
        'interface',
        staged?.display_name ||
          (isExistingChildItem(section_id, itemId, 'section_interface')
            ? uci.get(FORKOP_UCI_PACKAGE, itemId, 'display_name')
            : '') ||
          interfaceName,
        true,
        interfaceName,
      );
    },
  );
  currentSourceOptionValues(section_id, 'outbound_jsons').forEach(
    (value: unknown, index: number) => {
      const outbound = parseOutboundJsonObject(value);
      const type = `${outbound?.type || ''}`.trim().toLowerCase();
      add(
        'json',
        outboundJsonDisplayTag(value) || `JSON outbound #${index + 1}`,
        !GROUP_OUTBOUND_TYPES.includes(type),
      );
    },
  );
  currentGroupNames(section_id, 'urltest', 'urltest').forEach((name) =>
    add('urltest', name, false),
  );
  currentGroupNames(section_id, 'fallback_group', 'fallback_group').forEach(
    (name) => add('fallback', name, false),
  );

  return result;
}

// Servers and groups share the section's names, so the offer avoids all of them.
export function nextSectionChildName(section_id: string, prefix: string) {
  return nextNumberedName(
    prefix,
    sectionChildNames(section_id).map((child) => child.name),
  );
}

export function currentDraftOutboundNames(section_id: string) {
  return sectionChildNames(section_id)
    .filter((child) => child.member)
    .map((child) => child.name);
}

// "/" separates the name from the section in the name it runs under. Duplicates within one kind
// are the list's own check, unless the entry is named by its value.
export function validateSectionChildName(
  section_id: string,
  kind: SectionChildKind,
  value: unknown,
  own?: string,
): true | string {
  const name = `${value || ''}`.trim();
  if (name.includes('/')) {
    return message.slashInName();
  }
  return sectionChildNames(section_id).some(
    (child) =>
      child.name === name &&
      (child.kind !== kind || (own !== undefined && child.value !== own)),
  )
    ? message.nameTaken()
    : true;
}

export function validateSectionChildListName(
  section_id: string,
  kind: SectionChildKind,
  widget: CBIWidget,
  itemNode: Element | null,
  value: unknown,
): true | string {
  const unique = validateUniqueDynamicListItemName(widget, itemNode, value);
  return unique === true
    ? validateSectionChildName(section_id, kind, value)
    : unique;
}

// Follows the section form, so unsaved URLTest additions and removals show at once.
function currentUrlTestNameChoices(section_id: string) {
  return Array.from(
    new Set(currentGroupNames(section_id, 'urltest', 'urltest')),
  ).map((name) => ({ value: name, label: name }));
}

// A level that goes direct has no members, the one mode where this does not belong.
export function addUrlTestMemberOption(
  itemSection: CBISection,
  parentSectionForItem: (itemId: string) => string,
  modes: Array<{ value: string; label: string }>,
) {
  const option = itemSection.option(
    form.DynamicList,
    'include_groups',
    _('Add URLTest'),
    _('The group joins as the single node it has selected'),
  );
  modes
    .map((mode) => mode.value)
    .filter((mode) => mode !== 'direct')
    .forEach((mode) => option.depends('server_filter_mode', mode));
  option.rmempty = true;
  option.placeholder = _('-- Select --');
  option.load = function (itemId: string) {
    const values = normalizeOptionValues(
      optionMapValue(this, itemId, 'include_groups'),
    );
    refreshOptionChoices(
      this,
      currentUrlTestNameChoices(parentSectionForItem(itemId)),
    );
    return values;
  };
  configureLiveDynamicListChoices(
    option,
    (itemId: string) => currentUrlTestNameChoices(parentSectionForItem(itemId)),
    parentSectionForItem,
  );
  return option;
}

export function refreshLiveChoiceWidgets(section_id: string) {
  const refreshers = liveChoiceRefreshers.get(section_id);
  if (!refreshers) {
    return;
  }

  refreshers.forEach((refresh) => {
    if (refresh() === false) {
      refreshers.delete(refresh);
    }
  });

  if (refreshers.size === 0) {
    liveChoiceRefreshers.delete(section_id);
  }
}

function refreshAllLiveChoiceWidgets() {
  Array.from(liveChoiceRefreshers.keys()).forEach(refreshLiveChoiceWidgets);
}
