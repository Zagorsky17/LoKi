import { message } from '../../../validators/messages';
import { validateUrlField } from '../../../validators/validateUrl';
import { nextNumberedName } from '../../../helpers/nextNumberedName';
import { LOKI_UCI_PACKAGE, LATENCY_TEST_URL_OPTIONS } from '../../../constants';
import {
  applyChildItemSettings,
  childItemNameCheck,
  isExistingChildItem,
  nextSectionId,
  orderChildItemsByPosition,
  parentSectionIdForItem,
  removeChildItemsOf,
} from '../../cbi/childItems';
import { ButtonAddSettingsDynamicList } from '../../cbi/dynamicList';
import {
  childPendingSettingsStore,
  readChildSettings,
} from '../../cbi/itemSettings';
import {
  addDynamicListItem,
  dynamicListItemNames,
  renderChildItemLabel,
  updateDynamicListItemLabel,
  validateUniqueDynamicListItemName,
} from '../../cbi/listItems';
import { normalizeDynamicListItems } from '../../cbi/listValues';
import { showChildItemSettingsModal } from '../../cbi/modal';
import { requiredList } from '../../cbi/required';
import {
  addUrlTestMemberOption,
  nextSectionChildName,
  validateSectionChildListName,
} from './outboundNames';
import {
  addServerFilterOptions,
  groupServerFilterDescriptions,
} from './serverFilters';
import {
  addExpectedStatusOption,
  addGroupHealthCheckTailOptions,
} from './healthCheck';
import { validateRequiredSingBoxDuration } from '../../../validators/validateSingBoxDuration';

function fallbackGroupSettingsKeys() {
  return [
    'name',
    'health_check_url',
    'health_check_interval',
    'health_check_timeout',
    'attempt_timeout',
    'expected_status',
    'idle_timeout',
    'interrupt_exist_connections',
  ];
}

// A group is nothing without its levels, so removing one takes them along.
export function removeFallbackLevels(groupId: string) {
  removeChildItemsOf(groupId, 'fallback_level', 'group');
}

export function fallbackGroupChildDefaults() {
  return {
    health_check_url: 'https://www.gstatic.com/generate_204',
    health_check_interval: '5m',
    health_check_timeout: '5s',
    attempt_timeout: '5s',
    expected_status: '*',
    idle_timeout: '5m',
    interrupt_exist_connections: '0',
  };
}

function defaultFallbackGroupSettings(name: string = '') {
  return { name, ...fallbackGroupChildDefaults() };
}

function fallbackLevelSettingsKeys() {
  return [
    'name',
    'order',
    'server_filter_mode',
    'include_outbounds',
    'include_groups',
    'include_regex',
    'exclude_outbounds',
    'exclude_types',
    'exclude_regex',
  ];
}

function defaultFallbackLevelSettings() {
  return {
    name: '',
    order: '0',
    server_filter_mode: 'include',
  };
}

function fallbackLevelSettingsForValidation(
  groupId: string,
  levelId: string,
  option: CBIOption,
) {
  const store = childPendingSettingsStore(option, groupId);

  if (isExistingChildItem(groupId, levelId, 'fallback_level', 'group')) {
    return readChildSettings(
      levelId,
      fallbackLevelSettingsKeys(),
      defaultFallbackLevelSettings(),
    );
  }

  return Object.assign({}, store[levelId] || {});
}

function validateFallbackLevelItemsBeforeSave(
  groupId: string,
  values: unknown,
  option: CBIOption,
) {
  const normalizedValues = normalizeDynamicListItems(values);
  if (!normalizedValues.length) {
    return message.required();
  }

  const names = new Set();
  for (const value of normalizedValues) {
    const levelId = `${value || ''}`;
    const settings = fallbackLevelSettingsForValidation(
      groupId,
      levelId,
      option,
    );

    const name = `${settings.name || ''}`.trim();
    if (!name) return message.fixSettings();
    if (names.has(name)) return message.item(name, message.nameTaken());
    names.add(name);
  }

  return true;
}

function addFallbackLevelItemOptions(
  itemSection: CBISection,
  options: Partial<ChildItemDialogContext> = {},
) {
  const parentSectionForItem =
    typeof options.parentSectionId === 'function'
      ? options.parentSectionId
      : parentSectionIdForItem;

  const o = itemSection.option(form.Value, 'name', _('Group name'));
  o.validate = childItemNameCheck(options);

  const fallbackLevelModes = [
    { value: 'all', label: _('All remaining') },
    { value: 'exclude', label: _('All except selected') },
    { value: 'include', label: _('Only selected') },
    { value: 'direct', label: _('Direct') },
  ];
  addUrlTestMemberOption(itemSection, parentSectionForItem, fallbackLevelModes);

  addServerFilterOptions(itemSection, parentSectionForItem, {
    modeLabel: _('Server filter'),
    modeDescription: _('Which servers end up in the group'),
    modes: fallbackLevelModes,
    defaultMode: 'include',
    groupContext: true,
    ...groupServerFilterDescriptions(),
  });
}

function addFallbackGroupItemOptions(
  itemSection: CBISection,
  options: Partial<ChildItemDialogContext> = {},
) {
  const parentSectionForGroup =
    typeof options.parentSectionId === 'function'
      ? options.parentSectionId
      : parentSectionIdForItem;
  const ownerId =
    typeof options.ownerId === 'function' ? options.ownerId : () => '';

  let o = itemSection.option(form.Value, 'name', _('Group name'));
  o.validate = childItemNameCheck(options);

  o = itemSection.option(
    form.Value,
    'health_check_url',
    _('Check URL'),
    _('Availability check for every server'),
  );
  o.default = 'https://www.gstatic.com/generate_204';
  LATENCY_TEST_URL_OPTIONS.forEach((value: string) => o.value(value));
  o.validate = function (_itemId: string, value: unknown) {
    return validateUrlField(value);
  };

  addExpectedStatusOption(itemSection);

  o = itemSection.option(
    form.Value,
    'health_check_interval',
    _('Check interval'),
    _('How often every server of the group is checked'),
  );
  o.default = '5m';
  o.validate = function (_itemId: string, value: unknown) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Value,
    'health_check_timeout',
    _('Check timeout'),
    _('How long to wait for a server to answer'),
  );
  o.default = '5s';
  o.validate = function (_itemId: string, value: unknown) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Value,
    'attempt_timeout',
    _('Connection timeout'),
    _('How long to wait for a connection before moving to the next server'),
  );
  o.default = '5s';
  o.validate = function (_itemId: string, value: unknown) {
    return validateRequiredSingBoxDuration(value);
  };

  addGroupHealthCheckTailOptions(itemSection, '5m', 'health_check_interval');

  o = itemSection.option(
    ButtonAddSettingsDynamicList,
    'fallback_level',
    _('Server groups'),
    _('Checked from top to bottom until the first working server'),
  );
  o.rmempty = false;
  o.modalonly = true;
  o.addButtonLabel = _('+ Add servers');
  o.childType = 'fallback_level';
  o.ownerOption = 'group';
  o.childOwnerId = ownerId;
  o.parentSectionId = parentSectionForGroup;
  o.childValueOption = 'name';
  o.childDefaults = defaultFallbackLevelSettings();
  o.createId = () => nextSectionId('fallback_level');
  o.renderItemSettingsModal = showFallbackLevelSettingsModal;
  o.validateItemsOnSave = function (groupId: string, values: unknown) {
    return validateFallbackLevelItemsBeforeSave(groupId, values, this);
  };
  o.validate = requiredList();
  o.afterMaterializeChildItems = orderChildItemsByPosition;
  o.renderListItemLabel = function (groupId: string, itemId: string) {
    return renderChildItemLabel(this, groupId, itemId);
  };
}

function showFallbackLevelSettingsModal(
  groupId: string,
  itemValue: unknown,
  option: CBIOption,
  widget: CBIWidget,
  itemNode: Element | null,
  context: ChildItemModalContext = {},
) {
  const defaults = defaultFallbackLevelSettings();
  if (context.adding) {
    defaults.name = nextNumberedName('Group', dynamicListItemNames(widget));
  }

  return showChildItemSettingsModal(groupId, itemValue, option, {
    typeName: 'fallback_level',
    ownerOption: 'group',
    valueOption: 'name',
    keys: fallbackLevelSettingsKeys(),
    itemNode,
    defaults,
    addOptions: (itemSection: CBISection) =>
      addFallbackLevelItemOptions(itemSection, {
        parentSectionId: () => `${context.parentSectionId ?? ''}`,
        validateName: validateUniqueDynamicListItemName.bind(
          null,
          widget,
          itemNode,
        ),
      }),
    title: (name: string) => {
      const normalized = `${name || ''}`.trim();
      return normalized
        ? _('Server group: %s').format(normalized)
        : _('Server group settings');
    },
    afterSave: (
      itemId: string,
      inputValue: unknown,
      settings: ChildSettings,
      existing: boolean,
    ) => {
      const displayName = `${settings.name || inputValue || ''}`.trim();

      if (existing) {
        updateDynamicListItemLabel(itemNode, displayName);
        return;
      }

      if (context.adding) {
        addDynamicListItem(widget, displayName, displayName);
      } else {
        updateDynamicListItemLabel(itemNode, displayName);
      }
    },
  });
}

function createFallbackGroupItem(
  section_id: string,
  groupId: string,
  settings: ChildSettings,
) {
  const created =
    uci.add(LOKI_UCI_PACKAGE, 'fallback_group', groupId) || groupId;

  uci.set(LOKI_UCI_PACKAGE, created, 'section', section_id);
  Object.entries(fallbackGroupChildDefaults()).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') {
      uci.set(LOKI_UCI_PACKAGE, created, key, `${value}`);
    }
  });
  applyChildItemSettings(created, settings);

  return created;
}

export function showFallbackGroupSettingsModal(
  section_id: string,
  itemValue: unknown,
  option: CBIOption,
  widget: CBIWidget,
  itemNode: Element | null,
  context: ChildItemModalContext = {},
) {
  const groupId = context.adding
    ? nextSectionId('fallback_group')
    : `${itemValue || ''}`.trim();

  if (!groupId) {
    return null;
  }

  const defaultName = context.adding
    ? nextSectionChildName(section_id, 'Fallback')
    : '';

  return showChildItemSettingsModal(section_id, groupId, option, {
    typeName: 'fallback_group',
    valueOption: 'name',
    keys: fallbackGroupSettingsKeys(),
    defaults: defaultFallbackGroupSettings(defaultName),
    addOptions: addFallbackGroupItemOptions,
    validateName: (value: unknown) =>
      validateSectionChildListName(
        section_id,
        'fallback',
        widget,
        itemNode,
        value,
      ),
    title: (name: string) => {
      if (context.adding) {
        return _('Fallback settings');
      }

      const normalized = `${name || ''}`.trim();
      return normalized
        ? _('Fallback: %s').format(normalized)
        : _('Fallback settings');
    },
    afterSave: (
      itemId: string,
      inputValue: unknown,
      settings: ChildSettings,
      existing: boolean,
    ) => {
      const displayName = `${settings.name || inputValue || ''}`.trim();

      if (!existing) {
        const created = createFallbackGroupItem(section_id, groupId, settings);
        const store = childPendingSettingsStore(option, section_id);
        delete store[groupId];
        delete store[`${inputValue}`];
        delete store[displayName];
        addDynamicListItem(widget, created, displayName);
        return;
      }

      updateDynamicListItemLabel(itemNode, displayName);
    },
  });
}

export function validateFallbackGroupItemsBeforeSave(
  section_id: string,
  values: unknown,
) {
  for (const value of normalizeDynamicListItems(values)) {
    const groupId = `${value || ''}`.trim();

    if (
      !isExistingChildItem(section_id, groupId, 'fallback_group') ||
      !`${uci.get(LOKI_UCI_PACKAGE, groupId, 'name') || ''}`.trim()
    ) {
      return message.item(_('Fallback'), message.fixSettings());
    }
  }

  return true;
}
