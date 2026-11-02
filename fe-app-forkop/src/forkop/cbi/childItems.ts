import { FORKOP_UCI_PACKAGE } from '../../constants';
import { settingValueEquals } from './itemSettings';
import {
  findDynamicListItemByValue,
  setDynamicListItemValue,
} from './listItems';
import { normalizeDynamicListItems } from './listValues';
import { required } from './required';

// Section ids stay in the config for good, so they name their type; LuCI's createSID() "new"
// prefix would be written to /etc/config/forkop forever. Anonymous sections are addressed by
// position across the file, which shifts when another one is removed. The suffix is random, not
// the lowest free number: references are not cleared when their target goes, and a reused
// number would rebind them.
const SECTION_ID_PREFIXES: Record<string, string> = {
  connection_link: 'link',
  fallback_group: 'group',
  fallback_level: 'level',
  section: 'section',
  section_interface: 'iface',
  server: 'server',
  server_client: 'client',
  subscription_url: 'sub',
  urltest: 'urltest',
};

const issuedSectionIds = new Set<string>();

export function nextSectionId(typeName: string) {
  const prefix = SECTION_ID_PREFIXES[typeName] || typeName;

  for (let i = 0; i < 100; i += 1) {
    const id = `${prefix}_${Math.floor(Math.random() * 0x1000000)
      .toString(16)
      .padStart(6, '0')}`;

    // A staged child reaches uci only when its parent is saved, so ids issued in this dialog are
    // tracked here.
    if (!issuedSectionIds.has(id) && !uci.get(FORKOP_UCI_PACKAGE, id)) {
      issuedSectionIds.add(id);
      return id;
    }
  }

  return `${prefix}_${Date.now().toString(16)}`;
}

function childOwnerOption(ownerOption?: string) {
  return ownerOption || 'section';
}

function childItemOrder(item: UciSectionObject) {
  const value = item ? item.order : null;
  const parsed = Number.parseInt(value == null ? '0' : `${value}`, 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

export function getChildItemIds(
  section_id: string,
  typeName: string | undefined,
  ownerOption?: string,
): string[] {
  const ownerKey = childOwnerOption(ownerOption);
  const items = uci
    .sections(FORKOP_UCI_PACKAGE, typeName)
    .filter((item) => item[ownerKey] === section_id);

  if (['connection_link', 'fallback_level'].includes(typeName as string)) {
    items.sort((a, b) => {
      const orderDiff = childItemOrder(a) - childItemOrder(b);
      if (orderDiff !== 0) {
        return orderDiff;
      }

      return `${a['.name'] || ''}`.localeCompare(`${b['.name'] || ''}`);
    });
  }

  return items.map((item) => item['.name']).filter(Boolean);
}

function childItemValue(
  itemId: string,
  valueOption: string | undefined,
  fallback: string,
): string {
  if (!valueOption) {
    return itemId;
  }

  const value = uci.get(FORKOP_UCI_PACKAGE, itemId, valueOption);
  return value == null || value === '' ? fallback || itemId : `${value}`;
}

export function childItemInputValue(
  section_id: string,
  value: unknown,
  typeName: string | undefined,
  valueOption: string | undefined,
  ownerOption?: string,
): string {
  const itemId = `${value || ''}`;

  if (isExistingChildItem(section_id, itemId, typeName, ownerOption)) {
    return childItemValue(itemId, valueOption, itemId);
  }

  return itemId;
}

export function isExistingChildItem(
  section_id: string,
  itemId: string,
  typeName: string | undefined,
  ownerOption?: string,
): boolean {
  const ownerKey = childOwnerOption(ownerOption);

  return Boolean(
    itemId &&
      uci.get(FORKOP_UCI_PACKAGE, itemId, '.type') === typeName &&
      uci.get(FORKOP_UCI_PACKAGE, itemId, ownerKey) === section_id,
  );
}

export function createChildItem(
  section_id: string,
  options: ChildItemOptions,
  inputValue: unknown,
) {
  const rawValue = `${inputValue || ''}`.trim();

  // Only a stored child section id is an existing item; a display value is always a draft, so a
  // removed item added again under its name keeps the new settings.
  if (
    isExistingChildItem(
      section_id,
      rawValue,
      options.typeName,
      options.ownerOption,
    )
  ) {
    return {
      value: rawValue,
      text: options.valueOption
        ? childItemValue(rawValue, options.valueOption, rawValue)
        : rawValue,
      created: false,
    };
  }

  const requestedId =
    typeof options.createId === 'function'
      ? `${options.createId(rawValue, section_id) || ''}`.trim()
      : '';
  const itemId =
    (requestedId &&
      uci.add(FORKOP_UCI_PACKAGE, options.typeName as string, requestedId)) ||
    requestedId ||
    uci.add(FORKOP_UCI_PACKAGE, options.typeName as string);

  uci.set(
    FORKOP_UCI_PACKAGE,
    itemId,
    childOwnerOption(options.ownerOption),
    section_id,
  );

  if (options.valueOption) {
    uci.set(FORKOP_UCI_PACKAGE, itemId, options.valueOption, rawValue);
  }

  if (options.defaults && typeof options.defaults === 'object') {
    Object.entries(options.defaults).forEach(([key, value]) => {
      value =
        typeof value === 'function'
          ? value(rawValue, section_id, itemId)
          : value;
      if (value !== undefined && value !== null && value !== '') {
        uci.set(
          FORKOP_UCI_PACKAGE,
          itemId,
          key,
          Array.isArray(value)
            ? value.map((item) => `${item || ''}`).filter(Boolean)
            : `${value}`,
        );
      }
    });
  }

  return {
    value: itemId,
    text: options.valueOption ? rawValue : itemId,
    created: true,
  };
}

export function applyChildItemSettings(
  itemId: string,
  settings: ChildSettings | null | undefined,
) {
  Object.entries(settings || {}).forEach(([key, value]) => {
    if (!key || key.charAt(0) === '.') {
      return;
    }

    // LuCI counts writing an unchanged value as a change, so unchanged values are skipped.
    if (settingValueEquals(uci.get(FORKOP_UCI_PACKAGE, itemId, key), value)) {
      return;
    }

    if (value === undefined || value === null || value === '') {
      uci.unset(FORKOP_UCI_PACKAGE, itemId, key);
    } else if (Array.isArray(value)) {
      const values = value
        .map((item) => `${item || ''}`.trim())
        .filter((item) => item.length);
      if (values.length) {
        uci.set(FORKOP_UCI_PACKAGE, itemId, key, values);
      } else {
        uci.unset(FORKOP_UCI_PACKAGE, itemId, key);
      }
    } else {
      uci.set(FORKOP_UCI_PACKAGE, itemId, key, `${value}`);
    }
  });
}

export function materializeChildItems(
  section_id: string,
  options: ChildItemOptions,
  inputValue: unknown,
) {
  const itemIds: string[] = [];
  const seen = new Set<string>();
  const resolved = new Map<string, string>();

  normalizeDynamicListItems(inputValue).forEach((value) => {
    let itemId = resolved.get(value);

    if (itemId == null) {
      const createdItem = createChildItem(section_id, options, value);
      itemId = createdItem.value;
      const stagedSettings =
        createdItem.created && typeof options.stagedSettings === 'function'
          ? options.stagedSettings(value)
          : null;

      if (stagedSettings) {
        applyChildItemSettings(itemId, stagedSettings);
      }

      if (itemId) {
        resolved.set(value, itemId);
      }
    }

    if (itemId && !seen.has(itemId)) {
      seen.add(itemId);
      itemIds.push(itemId);
    }
  });

  return { itemIds, resolved };
}

// Replaces drafts with the section ids they were stored as, so a repeated write updates those
// sections instead of duplicating them.
export function adoptMaterializedChildItems(
  option: CBIOption,
  section_id: string,
  resolved: Map<string, string>,
) {
  let widget = null;

  try {
    widget = option.getUIElement(section_id);
  } catch (_error) {
    // The widget is not mounted; the stored ids are loaded on the next render.
  }

  if (!widget || !widget.node) {
    return;
  }

  resolved.forEach((itemId, value) => {
    if (itemId === value) {
      return;
    }

    const item = findDynamicListItemByValue(widget.node, value);
    if (item) {
      setDynamicListItemValue(item, itemId);
    }
  });
}

// A section nothing points at is unreachable, so an item's own children go with it.
export function removeChildItemsOf(
  parentId: string,
  childType: string,
  ownerOption: string,
) {
  getChildItemIds(parentId, childType, ownerOption).forEach(
    (itemId: string) => {
      uci.remove(FORKOP_UCI_PACKAGE, itemId);
    },
  );
}

export function cleanupRemovedChildItems(
  section_id: string,
  typeName: string | undefined,
  keepValues: unknown,
  ownerOption?: string,
  // Only the tab declaring the list knows what an item owns.
  removeNested?: (itemId: string) => void,
) {
  const keep = new Set(normalizeDynamicListItems(keepValues));

  getChildItemIds(section_id, typeName, ownerOption).forEach(
    (itemId: string) => {
      if (!keep.has(itemId)) {
        removeNested?.(itemId);
        uci.remove(FORKOP_UCI_PACKAGE, itemId);
      }
    },
  );
}

// The list hands in its own refusal, a name another item holds, when the dialog opens.
export function childItemNameCheck(dialog: {
  validateName?: ChildItemNameValidator;
}) {
  return required((_itemId, value) => dialog.validateName?.(value) ?? true);
}

// The uci list is ordered but the sections behind it are not, so each item stores its position.
export function orderChildItemsByPosition(
  _ownerId: string,
  itemIds: string[],
): void {
  itemIds.forEach((itemId: string, index: number) => {
    if (uci.get(FORKOP_UCI_PACKAGE, itemId, 'order') !== `${index}`) {
      uci.set(FORKOP_UCI_PACKAGE, itemId, 'order', `${index}`);
    }
  });
}

export function parentSectionIdForItem(itemId: string): string {
  return (uci.get(FORKOP_UCI_PACKAGE, itemId, 'section') as string) || '';
}
