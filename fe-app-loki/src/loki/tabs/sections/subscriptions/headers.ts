import { renderStackedJsonSettingsModal } from '../../../cbi/modal';
import { required } from '../../../cbi/required';

function subscriptionHeaderValues(value: unknown) {
  if (Array.isArray(value)) {
    return value.map((item) => `${item || ''}`).filter(Boolean);
  }
  return value ? [`${value}`] : [];
}

function parseSubscriptionHeader(value: unknown) {
  const line = `${value || ''}`;
  const separator = line.indexOf(':');
  return separator < 0
    ? { name: line.trim(), value: '' }
    : {
        name: line.slice(0, separator).trim(),
        value: line.slice(separator + 1).trim(),
      };
}

export function subscriptionHeaderRows(value: unknown) {
  return subscriptionHeaderValues(value).map((line, index: number) => ({
    '.name': `header_${index}`,
    '.type': 'header',
    ...parseSubscriptionHeader(line),
  }));
}

const validateSubscriptionHeaderName = required((_sectionId, value) =>
  /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(value.trim())
    ? true
    : _('Invalid header name'),
);

function validateSubscriptionHeaderValue(_sectionId: string, value: unknown) {
  return /[\r\n\0]/.test(`${value || ''}`)
    ? _('Line breaks are not allowed')
    : true;
}

export function subscriptionHeaderLines(map: CBIMap) {
  return map.data.sections(map.config, 'header').map((row) => {
    const name = `${row.name || ''}`.trim();
    const value = `${row.value || ''}`.trim();
    return `${name}:${value ? ` ${value}` : ''}`;
  });
}

export function syncSubscriptionHeaderRows(section: CBISection) {
  const configName = section.uciconfig ?? section.map.config;

  section.cfgsections().forEach((sectionId: string) => {
    section.children.forEach((option: CBIOption) => {
      if (!option.editable || option.modalonly) {
        return;
      }

      const value = option.formvalue(sectionId);
      if (value == null) {
        section.map.data.unset(configName, sectionId, option.option);
      } else {
        section.map.data.set(configName, sectionId, option.option, value);
      }
    });
  });
}

function refreshSubscriptionHeaderRows(section: CBISection) {
  return section.map.load().then(() => section.map.reset());
}

export function nextSubscriptionHeaderRowId(section: CBISection) {
  const configName = section.uciconfig ?? section.map.config;
  let sectionId: string;

  do {
    sectionId = `header_${section.nextHeaderRowIndex}`;
    section.nextHeaderRowIndex! += 1;
  } while (section.map.data.get(configName, sectionId) != null);

  return sectionId;
}

function addSubscriptionHeaderRow(section: CBISection) {
  syncSubscriptionHeaderRows(section);
  section.map.data.add(
    section.uciconfig ?? section.map.config,
    section.sectiontype,
    nextSubscriptionHeaderRowId(section),
  );
  return refreshSubscriptionHeaderRows(section);
}

function removeSubscriptionHeaderRow(section: CBISection, sectionId: string) {
  syncSubscriptionHeaderRows(section);
  section.map.data.remove(section.uciconfig ?? section.map.config, sectionId);
  return refreshSubscriptionHeaderRows(section);
}

export function showSubscriptionHeadersModal(
  parentMap: CBIMap,
  itemId: string,
) {
  const data = {
    header: subscriptionHeaderRows(
      parentMap.data.get(parentMap.config, itemId, 'header'),
    ),
  };
  const map = new form.JSONMap(data);
  const headers = map.section(form.GridSection, 'header', _('Headers'));
  headers.anonymous = true;
  headers.addremove = true;
  headers.sortable = false;
  headers.rowcolors = true;
  headers.nodescriptions = true;
  headers.hidetitle = true;
  headers.addbtntitle = _('Add header');
  headers.nextHeaderRowIndex = data.header.length;
  headers.handleAdd = function () {
    return addSubscriptionHeaderRow(this);
  };
  headers.handleRemove = function (sectionId: string) {
    return removeSubscriptionHeaderRow(this, sectionId);
  };
  headers.renderRowActions = function (sectionId: string) {
    return form.TableSection.prototype.renderRowActions.call(this, sectionId);
  };

  let o = headers.option(form.Value, 'name', _('Header name'));
  o.editable = true;
  o.validate = validateSubscriptionHeaderName;

  o = headers.option(form.Value, 'value', _('Header value'));
  o.editable = true;
  o.rmempty = true;
  o.validate = validateSubscriptionHeaderValue;

  return renderStackedJsonSettingsModal(_('Headers'), map, () => {
    parentMap.data.set(
      parentMap.config,
      itemId,
      'header',
      subscriptionHeaderLines(map),
    );
  });
}
