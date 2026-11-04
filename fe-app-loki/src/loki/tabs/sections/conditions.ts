import { message } from '../../../validators/messages';
import type { Check } from '../../../validators/types';
import { validateDomain } from '../../../validators/validateDomain';
import { validateSubnet } from '../../../validators/validateSubnet';
import {
  analyzeTextListValue,
  configureTextareaOption,
} from '../../cbi/annotatedTextarea';
import { normalizeOptionValues } from '../../cbi/listValues';
import {
  SYSTEM_DEVICE_VALUE,
  createLocalDeviceDynamicListWidget,
} from '../../cbi/localDevices';
import {
  getConfigListValues,
  stringArraysEqual,
  writeListOption,
} from '../../cbi/uci';
import { validateRegex } from './validators';

export function makeDeviceOptionsExclusive(
  firstOption: CBIOption,
  secondOption: CBIOption,
) {
  let changing = false;
  const firstWidgets: Record<string, CBIWidget> = {};
  const secondWidgets: Record<string, CBIWidget> = {};

  function removeMatches(
    section_id: string,
    value: unknown,
    otherWidgets: Record<string, CBIWidget>,
  ) {
    if (changing) {
      return;
    }

    const selected = new Set(normalizeOptionValues(value));
    if (!selected.size) {
      return;
    }

    const widget = otherWidgets[section_id];
    if (!widget) {
      return;
    }

    const current = normalizeOptionValues(widget.getValue());
    const filtered = current.filter((item) => !selected.has(item));
    if (stringArraysEqual(current, filtered)) {
      return;
    }

    changing = true;
    try {
      widget.setValue(filtered);
    } finally {
      changing = false;
    }
  }

  firstOption.onDeviceWidgetReady = function (
    section_id: string,
    widget: CBIWidget,
  ) {
    firstWidgets[section_id] = widget;
  };
  secondOption.onDeviceWidgetReady = function (
    section_id: string,
    widget: CBIWidget,
  ) {
    secondWidgets[section_id] = widget;
  };
  firstOption.onDeviceListChange = function (
    section_id: string,
    value: unknown,
  ) {
    removeMatches(section_id, value, secondWidgets);
  };
  secondOption.onDeviceListChange = function (
    section_id: string,
    value: unknown,
  ) {
    removeMatches(section_id, value, firstWidgets);
  };
}

// One value per line: every domain prefix the field understands, an address and both subnet
// kinds; luciPlaceholders.test.js runs each through its field's analyzer.
export const DOMAIN_CONDITION_PLACEHOLDER = [
  'example.com',
  'full:api.example.com',
  'keyword:google',
  String.raw`regex:^ads\..*\.com$`,
].join('\n');

const IP_CONDITION_PLACEHOLDER = [
  '1.1.1.1',
  '192.168.1.0/24',
  '2606:4700::/32',
].join('\n');

export const DESTINATION_CONDITION_PLACEHOLDER = [
  DOMAIN_CONDITION_PLACEHOLDER,
  IP_CONDITION_PLACEHOLDER,
].join('\n');

// No domain condition looks like this, so such an entry is read as an address and a mistyped one
// is told what an address needs.
const ADDRESS_SHAPE = /^[\d.]+(?:\/.*)?$|^[\da-f]*:[\da-f:.]*(?:\/.*)?$/i;

function validateDomainCondition(item: string): Check {
  const colonIndex = item.indexOf(':');
  const prefix = colonIndex > 0 ? item.slice(0, colonIndex) : '';
  const body = colonIndex > 0 ? item.slice(colonIndex + 1) : item;

  if (prefix && !['full', 'keyword', 'regex'].includes(prefix)) {
    return _('Prefixes: full:, keyword:, regex:');
  }
  if (prefix && !body.length) {
    return _('Nothing after %s').format(`${prefix}:`);
  }
  if (prefix === 'keyword') {
    return true;
  }
  if (prefix === 'regex') {
    return validateRegex(body);
  }
  return body.includes('/')
    ? message.invalidDomain()
    : validateDomain(body, true);
}

function analyzeConditionText(value: unknown, validateItem: TextItemValidator) {
  return analyzeTextListValue(value, validateItem, {
    normalizeDuplicateValue: (item) => `${item}`.toLowerCase(),
  });
}

export function analyzeDestinationText(value: unknown) {
  return analyzeConditionText(value, (item) =>
    ADDRESS_SHAPE.test(item)
      ? validateSubnet(item)
      : validateDomainCondition(item),
  );
}

export function analyzeDnsDestinationText(value: unknown) {
  return analyzeConditionText(value, (item) =>
    validateSubnet(item) === true
      ? _('Domains only')
      : validateDomainCondition(item),
  );
}

export function validatePortCondition(_section_id: string, value: unknown) {
  const normalized = value ? `${value}`.trim() : '';

  if (!normalized.length) {
    return true;
  }

  const match = normalized.match(/^(\d+)(?:-(\d+))?$/);
  if (!match) {
    return _('Format: 80 or 1000-2000');
  }

  const start = Number.parseInt(match[1], 10);
  const end = match[2] ? Number.parseInt(match[2], 10) : start;

  if (start < 1 || start > 65535 || end < 1 || end > 65535) {
    return message.invalidPort();
  }

  return start > end ? message.rangeReversed() : true;
}

interface ConditionFieldConfig {
  key: string;
  label: string;
  description?: string;
  placeholder?: string;
  dynamicValidate?: OptionValidator;
}

function configureConditionListStorage(o: CBIOption, key: string) {
  o.load = function (section_id: string) {
    return getConfigListValues(section_id, key);
  };

  o.write = function (section_id: string, value: unknown) {
    writeListOption(section_id, key, value);
  };
}

export function addDynamicConditionField(
  section: CBISection,
  config: ConditionFieldConfig,
) {
  const o = section.taboption(
    'conditions',
    form.DynamicList,
    config.key,
    config.label,
    config.description,
  );

  o.modalonly = true;
  if (config.placeholder) {
    o.placeholder = config.placeholder;
  }
  if (config.dynamicValidate) {
    o.validate = config.dynamicValidate;
  }

  configureConditionListStorage(o, config.key);

  return o;
}

export function addLocalDeviceSubnetDynamicField(
  section: CBISection,
  config: ConditionFieldConfig,
) {
  const o = section.taboption(
    'conditions',
    form.DynamicList,
    config.key,
    config.label,
    config.description,
  );

  o.modalonly = true;
  o.placeholder = _('Device or IP');
  o.validate = function (_section_id: string, value: string) {
    if (!value || value.length === 0) {
      return true;
    }
    if (value === SYSTEM_DEVICE_VALUE) {
      return true;
    }

    return validateSubnet(value);
  };
  configureConditionListStorage(o, config.key);
  o.renderWidget = function (
    section_id: string,
    _option_index,
    cfgvalue: unknown,
  ) {
    return createLocalDeviceDynamicListWidget(this, section_id, cfgvalue);
  };

  return o;
}

// A DNS section matches domains only and gets a field of its own over the same destinations text;
// the hidden field leaves it alone.
export function addDestinationField(
  section: CBISection,
  name: string,
  label: string,
  placeholder: string,
  analyze: TextAnalyzer,
  description?: string,
) {
  const o = section.taboption(
    'conditions',
    form.TextValue,
    name,
    label,
    description,
  );

  o.ucioption = 'destinations';
  o.retain = true;
  o.rows = 8;
  o.wrap = 'soft';
  o.textarea = true;
  o.modalonly = true;
  o.placeholder = placeholder;
  o.validate = function (_section_id: string, value: string) {
    const analysis = analyze(value);
    return analysis.valid ? true : `${analysis.message}`;
  };
  configureTextareaOption(o, analyze);

  return o;
}
