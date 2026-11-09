import { LOKI_UCI_PACKAGE } from '../../../constants';
import { getProxyUrlName } from '../../../helpers/getProxyUrlName';
import { nextNumberedName } from '../../../helpers/nextNumberedName';
import { validateProxyUrl } from '../../../validators/validateProxyUrl';
import { getChildItemIds, isExistingChildItem } from '../../cbi/childItems';
import { updateDynamicListItemLabel } from '../../cbi/listItems';
import { showChildItemSettingsModal } from '../../cbi/modal';
import { required } from '../../cbi/required';
import { E } from '../../../helpers/element';
import { addCascadeOptions } from './cascade';
import { validateConnectionUriCore } from './coreSupport';
import {
  refreshLiveChoiceWidgets,
  sectionChildNames,
  validateSectionChildListName,
} from './outboundNames';

export function validateConnectionLink(value: unknown) {
  const link = `${value ?? ''}`.trim();
  if (!link) {
    return true;
  }

  const validation = validateProxyUrl(link);
  return validation === true ? validateConnectionUriCore(link) : validation;
}

// As the dialog holds them now, or the stored links when the list is not on screen.
function listedLinkValues(sectionId: string, option: CBIOption): string[] {
  let values: unknown = null;
  try {
    values = option && option.formvalue ? option.formvalue(sectionId) : null;
  } catch (_error) {
    values = null;
  }

  return Array.isArray(values)
    ? values.map((value) => `${value || ''}`.trim()).filter(Boolean)
    : getChildItemIds(sectionId, 'connection_link');
}

// A link still in the add field is no entry yet and holds no name.
function listedLinkName(sectionId: string, value: string) {
  return isExistingChildItem(sectionId, value, 'connection_link')
    ? `${uci.get(LOKI_UCI_PACKAGE, value, 'name') || ''}`.trim()
    : '';
}

// Named after the server it describes ("／" for "/"), or "Node #N"; a name the section already
// holds gets "#1" and up, so the same link added twice is two servers.
export function nextLinkName(
  sectionId: string,
  option: CBIOption,
  link: string,
) {
  const linkNames = listedLinkValues(sectionId, option)
    .map((value) => listedLinkName(sectionId, value))
    .filter(Boolean);
  const taken = new Set([
    ...linkNames,
    ...sectionChildNames(sectionId)
      .filter((child) => child.kind !== 'link')
      .map((child) => child.name),
  ]);
  const own = getProxyUrlName(link).trim().replaceAll('/', '／');
  if (own && !taken.has(own)) {
    return own;
  }
  return nextNumberedName(own || 'Node', [...taken]);
}

export function connectionLinkListItemLabel(sectionId: string, value: string) {
  return E(
    'span',
    { class: 'fkp-dynlist-label' },
    listedLinkName(sectionId, value),
  );
}

function connectionLinkSettingsKeys() {
  return ['name', 'uri', 'detour_section'];
}

function writeTrimmed(this: CBIOption, itemId: string, value: unknown) {
  return form.Value.prototype.write.call(this, itemId, `${value ?? ''}`.trim());
}

export function showConnectionLinkSettingsModal(
  sectionId: string,
  itemValue: unknown,
  option: CBIOption,
  widget: CBIWidget,
  itemNode: Element | null,
) {
  const name = listedLinkName(sectionId, `${itemValue ?? ''}`);
  return showChildItemSettingsModal(sectionId, itemValue, option, {
    typeName: 'connection_link',
    valueOption: 'uri',
    keys: connectionLinkSettingsKeys(),
    itemNode,
    defaults: (inputValue: string) => ({ uri: inputValue, name }),
    addOptions: (itemSection: CBISection) => {
      let o = itemSection.option(form.Value, 'name', _('Server name'));
      o.write = writeTrimmed;
      o.validate = required(function (_itemId, value) {
        return validateSectionChildListName(
          sectionId,
          'link',
          widget,
          itemNode,
          value,
        );
      });

      o = itemSection.option(form.Value, 'uri', _('Connection URI'));
      // A link carries the credentials of its server.
      o.password = true;
      o.write = writeTrimmed;
      o.validate = required((_itemId, value) => validateConnectionLink(value));

      addCascadeOptions(
        itemSection,
        () => sectionId,
        _('Connect to the server through another section'),
      );
    },
    title: () => (name ? _('Server: %s').format(name) : _('Server settings')),
    afterSave: (
      _itemId: string,
      _inputValue: string,
      settings: ChildSettings,
    ) => {
      updateDynamicListItemLabel(itemNode, `${settings.name || ''}`.trim());
      refreshLiveChoiceWidgets(sectionId);
    },
  });
}
