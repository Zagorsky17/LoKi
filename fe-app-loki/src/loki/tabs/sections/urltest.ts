import { LOKI_UCI_PACKAGE, LATENCY_TEST_URL_OPTIONS } from '../../../constants';
import { validateUrlField } from '../../../validators/validateUrl';
import {
  childItemNameCheck,
  isExistingChildItem,
  parentSectionIdForItem,
} from '../../cbi/childItems';
import { childPendingSettingsStore } from '../../cbi/itemSettings';
import {
  addDynamicListItem,
  updateDynamicListItemLabel,
} from '../../cbi/listItems';
import { normalizeDynamicListItems } from '../../cbi/listValues';
import { showChildItemSettingsModal } from '../../cbi/modal';
import { message } from '../../../validators/messages';
import {
  addExpectedStatusOption,
  addGroupHealthCheckTailOptions,
} from './healthCheck';
import {
  addServerFilterOptions,
  groupServerFilterDescriptions,
} from './serverFilters';
import {
  nextSectionChildName,
  validateSectionChildListName,
} from './outboundNames';
import { optionMapValue } from './subscriptions/model';
import { validateRequiredSingBoxDuration } from '../../../validators/validateSingBoxDuration';

function validateUrlTestTolerance(value: unknown) {
  const normalized = `${value ?? ''}`.trim();
  if (!normalized) {
    return message.required();
  }
  return /^[0-9]+$/.test(normalized) && Number(normalized) <= 10000
    ? true
    : message.wholeNumber(0, 10000);
}

function urlTestSettingsKeys() {
  return [
    'name',
    'check_interval',
    'tolerance',
    'testing_url',
    'expected_status',
    'idle_timeout',
    'interrupt_exist_connections',
    'server_filter_mode',
    'include_outbounds',
    'include_regex',
    'exclude_outbounds',
    'exclude_types',
    'exclude_regex',
  ];
}

export function urlTestChildDefaults() {
  return {
    check_interval: '3m',
    tolerance: '50',
    testing_url: 'https://www.gstatic.com/generate_204',
    expected_status: '*',
    idle_timeout: '30m',
    interrupt_exist_connections: '0',
    server_filter_mode: 'all',
  };
}

function defaultUrlTestSettings(name: string) {
  return { name: `${name || ''}`, ...urlTestChildDefaults() };
}

function addUrlTestItemOptions(
  itemSection: CBISection,
  options: Partial<ChildItemDialogContext> = {},
) {
  const parentSectionForItem =
    typeof options.parentSectionId === 'function'
      ? options.parentSectionId
      : parentSectionIdForItem;

  let o = itemSection.option(form.Value, 'name', _('Group name'));
  o.load = function (itemId: string) {
    return optionMapValue(this, itemId, 'name') || '';
  };
  o.validate = childItemNameCheck(options);

  o = itemSection.option(
    form.Value,
    'testing_url',
    _('Check URL'),
    _('Latency measurement for every server'),
  );
  o.default = 'https://www.gstatic.com/generate_204';
  LATENCY_TEST_URL_OPTIONS.forEach((value: string) => o.value(value));
  o.validate = function (_itemId: string, value: unknown) {
    return validateUrlField(value);
  };

  addExpectedStatusOption(itemSection);

  o = itemSection.option(
    form.Value,
    'check_interval',
    _('Check interval'),
    _('How often every server of the group is checked'),
  );
  o.default = '3m';
  o.validate = function (_itemId: string, value: unknown) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Value,
    'tolerance',
    _('Latency difference'),
    _('Switching threshold in ms at which to move to a faster server'),
  );
  o.default = '50';
  o.validate = function (_itemId: string, value: unknown) {
    return validateUrlTestTolerance(value);
  };

  addGroupHealthCheckTailOptions(itemSection, '30m', 'check_interval');

  addServerFilterOptions(itemSection, parentSectionForItem, {
    groupContext: true,
    modeLabel: _('Server filter'),
    modeDescription: _('Which servers end up in the group'),
    modes: [
      { value: 'all', label: _('All servers') },
      { value: 'exclude', label: _('All except selected') },
      { value: 'include', label: _('Only selected') },
    ],
    ...groupServerFilterDescriptions(),
  });
}

export function showUrlTestSettingsModal(
  _section_id: string,
  itemValue: unknown,
  option: CBIOption,
  widget: CBIWidget,
  itemNode: Element | null,
  context: ChildItemModalContext = {},
) {
  const defaultName = context.adding
    ? nextSectionChildName(_section_id, 'URLTest')
    : '';
  return showChildItemSettingsModal(_section_id, itemValue, option, {
    typeName: 'urltest',
    valueOption: 'name',
    keys: urlTestSettingsKeys(),
    itemNode,
    defaults: () => defaultUrlTestSettings(defaultName),
    addOptions: addUrlTestItemOptions,
    validateName: (value: unknown) =>
      validateSectionChildListName(
        _section_id,
        'urltest',
        widget,
        itemNode,
        value,
      ),
    title: (name: string) => {
      const normalized = `${name || ''}`.trim();
      return !normalized || /^urltest-[a-z0-9]+-\d+$/.test(normalized)
        ? _('URLTest settings')
        : _('URLTest: %s').format(normalized);
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

export function validateUrlTestItemsBeforeSave(
  section_id: string,
  values: unknown,
  option: CBIOption,
) {
  const store = childPendingSettingsStore(option, section_id);

  for (const value of normalizeDynamicListItems(values)) {
    const itemId = `${value || ''}`;
    let name = '';

    if (isExistingChildItem(section_id, itemId, 'urltest')) {
      name = `${uci.get(LOKI_UCI_PACKAGE, itemId, 'name') || ''}`;
    } else if (store[itemId]) {
      name = `${store[itemId].name || ''}`;
    }

    if (!`${name || ''}`.trim()) {
      return message.item(_('URLTest'), message.fixSettings());
    }
  }

  return true;
}
