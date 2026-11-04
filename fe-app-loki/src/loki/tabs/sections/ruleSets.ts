import {
  DOMAIN_LIST_INCLUDES,
  DOMAIN_LIST_OPTIONS,
  LOKI_UCI_PACKAGE,
} from '../../../constants';
import { showToast } from '../../../helpers/showToast';
import { message } from '../../../validators/messages';
import { validatePath } from '../../../validators/validatePath';
import { validateUrl } from '../../../validators/validateUrl';
import { itemSettingsFlag, readItemSettingsMap } from '../../cbi/itemSettings';
import { dynamicListItemValues } from '../../cbi/listItems';
import {
  normalizeDynamicListItems,
  uniqueDynamicListItems,
} from '../../cbi/listValues';
import { renderStackedJsonSettingsModal } from '../../cbi/modal';
import { getConfigListValues, writeListOption } from '../../cbi/uci';
import { getRuleResolvedAction } from './actions';
import { RULE_SET_ITEM_SETTINGS_KEY } from './constants';

function ruleSetIncludesSubnets(section_id: string, value: string) {
  const settings = readItemSettingsMap(section_id, RULE_SET_ITEM_SETTINGS_KEY);
  const itemSettings = settings && settings[value];

  if (
    itemSettings &&
    typeof itemSettings === 'object' &&
    itemSettings.include_subnets != null
  ) {
    return itemSettingsFlag(itemSettings, 'include_subnets', false);
  }

  return getConfigListValues(section_id, 'rule_set_with_subnets').includes(
    value,
  );
}

// URLs and paths are too long for a dialog title; the file name tells them apart.
function ruleSetFileName(reference: string) {
  const path = reference.trim().split(/[?#]/u, 1)[0].replace(/\/+$/u, '');
  return path.slice(path.lastIndexOf('/') + 1);
}

export function showRuleSetSettingsModal(
  section_id: string,
  itemValue: unknown,
  option: CBIOption,
  widget: CBIWidget,
) {
  const data = {
    settings: {
      include_subnets: ruleSetIncludesSubnets(section_id, `${itemValue ?? ''}`)
        ? '1'
        : '0',
    },
  };
  const map = new form.JSONMap(data);
  const section = map.section(form.NamedSection, 'settings');
  section.anonymous = true;
  section.addremove = false;

  const includeSubnets = section.option(
    form.Flag,
    'include_subnets',
    _('Include IP addresses and subnets'),
    _(
      'By default only the domain conditions of a rule set are applied. This option adds its IP addresses and subnets to nftables. Large lists can load the router heavily. Enable it only if you know the set holds the subnets you need',
    ),
  );
  includeSubnets.default = '0';
  includeSubnets.rmempty = false;

  const name = ruleSetFileName(`${itemValue ?? ''}`);
  return renderStackedJsonSettingsModal(
    name ? _('Rule set: %s').format(name) : _('Rule set settings'),
    map,
    (settings: ChildSettings) => {
      const value = settings.include_subnets === '1';
      const refs = uniqueDynamicListItems(
        widget && typeof widget.getValue === 'function'
          ? widget.getValue()
          : getCustomRulesetReferences(section_id),
      );
      const subnets = new Set(
        getConfigListValues(section_id, 'rule_set_with_subnets').filter((ref) =>
          refs.includes(ref),
        ),
      );

      if (value) {
        subnets.add(`${itemValue}`);
      } else {
        subnets.delete(`${itemValue}`);
      }

      writeListOption(
        section_id,
        'rule_set',
        refs.filter((ref) => !subnets.has(ref)),
      );
      writeListOption(section_id, 'rule_set_with_subnets', [...subnets]);
      if (option && typeof option.getUIElement === 'function') {
        option.getUIElement(section_id)!.setValue(refs);
      }
    },
  );
}

export function loadRulesetValues(option: CBIOption) {
  delete option.keylist;
  delete option.vallist;

  Object.entries(DOMAIN_LIST_OPTIONS).forEach(([key, label]) => {
    option.value(key, label);
  });
}

function isBuiltinRulesetValue(value: string) {
  return Object.prototype.hasOwnProperty.call(DOMAIN_LIST_OPTIONS, value);
}

function builtinListLabel(value: string) {
  return (DOMAIN_LIST_OPTIONS as Record<string, string>)[value] ?? value;
}

// Why a list picked beside the selected ones would add nothing, or null: a selected regional list
// holds it, or it holds some of the selected ones.
export function builtinListRefusal(selected: string[], picked: string) {
  const holder = selected.find((value) =>
    (DOMAIN_LIST_INCLUDES[value] ?? []).includes(picked),
  );
  if (holder) {
    return _('%s is already in %s').format(
      builtinListLabel(picked),
      builtinListLabel(holder),
    );
  }

  const held = selected.filter((value) =>
    (DOMAIN_LIST_INCLUDES[picked] ?? []).includes(value),
  );
  if (held.length === 0) {
    return null;
  }
  const names = held.map(builtinListLabel).join(', ');
  return (
    held.length === 1
      ? _('%s is already in %s: remove it first')
      : _('%s are already in %s: remove them first')
  ).format(names, builtinListLabel(picked));
}

// LuCI adds a picked list in a listener on the list itself; this one runs first, in the capture
// phase, and keeps a list out that the selection already holds or that would hold the selection.
export function refuseHeldBuiltinLists(dl: HTMLElement) {
  dl.addEventListener(
    'cbi-dropdown-change',
    (event) => {
      const detail = (event as CustomEvent).detail;
      const picked = detail?.value?.value;
      if (picked == null) {
        return;
      }
      const refusal = builtinListRefusal(
        dynamicListItemValues(dl),
        `${picked}`,
      );
      if (refusal) {
        event.stopImmediatePropagation();
        detail.instance.setValues(detail.element, null);
        showToast(refusal, 'error');
      }
    },
    true,
  );
}

// The backend refuses a YAML list by its extension.
export function validateCustomRulesetReference(value: string) {
  if (!value) {
    return true;
  }
  if (/\.ya?ml$/i.test(value.replace(/[?#].*$/, ''))) {
    return _('YAML is not supported');
  }
  const valid =
    value.startsWith('http://') || value.startsWith('https://')
      ? validateUrl(value) === true
      : value.startsWith('/') && validatePath(value) === true;
  return valid ? true : message.urlOrPath();
}

function getRulesetReferences(section_id: string) {
  return getConfigListValues(section_id, 'rule_set');
}

export function getBuiltInRulesetReferences(section_id: string) {
  const values = getConfigListValues(section_id, 'community_lists').filter(
    (value: string) => isBuiltinRulesetValue(value),
  );

  return values.filter(
    (value: string, index: number, all: string[]) =>
      isBuiltinRulesetValue(value) && all.indexOf(value) === index,
  );
}

export function getCustomRulesetReferences(section_id: string) {
  return uniqueDynamicListItems([
    ...getRulesetReferences(section_id).filter(
      (value: string) => !isBuiltinRulesetValue(value),
    ),
    ...getConfigListValues(section_id, 'rule_set_with_subnets'),
  ]);
}

export function writeBuiltInRulesetReferences(
  section_id: string,
  values: unknown,
) {
  const refs = normalizeDynamicListItems(values).filter((value: string) =>
    isBuiltinRulesetValue(value),
  );
  writeListOption(section_id, 'community_lists', refs);
}

export function writeCustomRulesetReferences(
  section_id: string,
  values: unknown,
) {
  const refs = uniqueDynamicListItems(values);
  if (getRuleResolvedAction(section_id) === 'dns') {
    writeDnsRulesetReferences(section_id, refs);
    return;
  }
  const subnetRefs = getConfigListValues(
    section_id,
    'rule_set_with_subnets',
  ).filter((value: string) => refs.includes(value));
  const subnetRefSet = new Set(subnetRefs);

  writeListOption(
    section_id,
    'rule_set',
    refs.filter((value: string) => !subnetRefSet.has(value)),
  );
  writeListOption(section_id, 'rule_set_with_subnets', subnetRefs);
  uci.unset(LOKI_UCI_PACKAGE, section_id, RULE_SET_ITEM_SETTINGS_KEY);
}

export function writeDnsRulesetReferences(section_id: string, values: unknown) {
  writeListOption(section_id, 'rule_set', uniqueDynamicListItems(values));
  uci.unset(LOKI_UCI_PACKAGE, section_id, 'rule_set_with_subnets');
  uci.unset(LOKI_UCI_PACKAGE, section_id, RULE_SET_ITEM_SETTINGS_KEY);
}
