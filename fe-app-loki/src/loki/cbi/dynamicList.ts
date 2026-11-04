import { LOKI_UCI_PACKAGE } from '../../constants';
import {
  adoptMaterializedChildItems,
  childItemInputValue,
  cleanupRemovedChildItems,
  createChildItem,
  getChildItemIds,
  materializeChildItems,
} from './childItems';
import {
  childPendingSettingsStore,
  clearChildPendingSettings,
} from './itemSettings';
import {
  dynamicListItemCurrentValue,
  dynamicListItemValues,
  findDynamicListItemByValue,
  updateButtonAddDynamicListLayout,
} from './listItems';
import { E } from '../../helpers/element';
import { renderSettingsIcon24 } from '../../icons';

const CONNECTIONS_DYNLIST_STYLE_ID = 'fkp-connections-dynlist-styles';

function ensureConnectionsDynamicListStyles() {
  if (document.getElementById(CONNECTIONS_DYNLIST_STYLE_ID)) {
    return;
  }

  document.head.appendChild(
    E(
      'style',
      { id: CONNECTIONS_DYNLIST_STYLE_ID },
      `
.fkp-connections-dynlist {
  column-gap: 4px;
  display: inline-grid;
  grid-template-columns: minmax(0, 1fr) auto;
}

.fkp-connections-dynlist > .item {
  grid-column: 1;
  min-inline-size: 0;
}

.fkp-connections-dynlist > .fkp-dynlist-settings {
  align-items: center;
  align-self: start;
  block-size: var(--fkp-dynlist-row-size, auto);
  box-sizing: border-box;
  display: inline-flex;
  grid-column: 2;
  inline-size: 2.5em !important;
  justify-content: center;
  line-height: 1;
  margin: 0;
  min-block-size: 0;
  min-inline-size: 0;
  padding: 0;
  user-select: none;
}

.fkp-connections-dynlist > .fkp-dynlist-settings > svg {
  block-size: 16px;
  display: block;
  inline-size: 16px;
}

.fkp-connections-dynlist > .add-item {
  grid-column: 1 / -1;
}

.fkp-connections-dynlist > .add-item > .cbi-dropdown {
  width: 100%;
  max-width: none;
}

.fkp-button-add-dynlist.cbi-input-invalid {
  box-shadow: none;
}

.fkp-interface-dynlist-label {
  align-items: center;
  display: inline-flex;
  gap: 0.25em;
  max-width: 100%;
  vertical-align: middle;
}

.fkp-interface-dynlist-label > img {
  flex: 0 0 auto;
  height: 1.35em;
  width: auto;
}

.fkp-interface-dynlist-label > span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

body.modal-overlay-active > #modal_overlay > .modal.cbi-modal > .cbi-map.flash {
  animation: none !important;
}

`,
    ),
  );
}

const SettingsUIDynamicList = ui.DynamicList.extend({
  render() {
    ensureConnectionsDynamicListStyles();
    this.settingsButtonResizeObserver?.disconnect();
    this.settingsButtonResizeObserver =
      typeof ResizeObserver === 'function'
        ? new ResizeObserver((entries) => {
            entries.forEach((entry) => {
              this.syncSettingsButtonSize(entry.target);
            });
          })
        : null;

    const node = ui.DynamicList.prototype.render.call(this);
    node.classList.add('fkp-connections-dynlist');
    node.addEventListener('cbi-dynlist-change', () => {
      this.syncSettingsButtons(node);
    });
    node.addEventListener('touchstart', () => this.syncSettingsButtons(node));
    node.addEventListener('touchmove', () => this.syncSettingsButtons(node));
    return node;
  },

  syncSettingsButtonSize(item: Element | null) {
    const button = item && item.fkpDynamicListSettingsButton;
    const height = (item as HTMLElement | null)?.offsetHeight;
    if (button && (height as number) > 0) {
      button.style.setProperty('--fkp-dynlist-row-size', `${height}px`);
    }
  },

  syncSettingsButtons(dl: HTMLElement) {
    Array.from(dl.children).forEach((item) => {
      const button = item.fkpDynamicListSettingsButton;
      if (
        item.classList.contains('item') &&
        button &&
        button.parentNode === dl &&
        item.nextElementSibling !== button
      ) {
        item.after(button);
      }
    });
  },

  addItem(
    dl: HTMLElement,
    value: string,
    text: string | null,
    flash?: boolean,
  ) {
    if (flash && typeof this.options.createItem === 'function') {
      value = this.options.createItem(value);
      text = null;
    } else if (
      flash &&
      typeof this.options.hasEquivalentValue === 'function' &&
      this.options.hasEquivalentValue(value, dl)
    ) {
      this.dispatchCbiDynlistChange(dl, value);
      return;
    }

    const itemText =
      typeof this.options.itemLabel === 'function'
        ? this.options.itemLabel(value, text)
        : text;

    ui.DynamicList.prototype.addItem.call(this, dl, value, itemText, flash);

    const item = findDynamicListItemByValue(dl, value);
    const hasSettings =
      typeof this.options.hasSettings === 'function'
        ? this.options.hasSettings(value)
        : true;

    if (!item || item.fkpDynamicListSettingsButton || !hasSettings) {
      return;
    }

    const settingsButton = E(
      'button',
      {
        type: 'button',
        class: 'btn cbi-button cbi-button-neutral fkp-dynlist-settings',
        title: _('Settings'),
        'aria-label': _('Settings'),
        disabled: this.options.disabled ? '' : null,
        click: (event) => {
          event.preventDefault();
          event.stopPropagation();

          if (this.options.disabled) {
            return;
          }

          if (typeof this.options.settingsHandler === 'function') {
            this.options.settingsHandler(
              dynamicListItemCurrentValue(item, value),
              item,
              this,
              {},
            );
          }
        },
      },
      renderSettingsIcon24(),
    );
    item.fkpDynamicListSettingsButton = settingsButton;
    item.after(settingsButton);
    this.settingsButtonResizeObserver?.observe(item);
    this.syncSettingsButtonSize(item);
  },

  removeItem(dl: HTMLElement, item: Element) {
    const settingsButton = item && item.fkpDynamicListSettingsButton;
    this.settingsButtonResizeObserver?.unobserve(item);
    if (settingsButton && settingsButton.parentNode === dl) {
      settingsButton.remove();
    }

    return ui.DynamicList.prototype.removeItem.call(this, dl, item);
  },

  handleClick(event: Event) {
    if ((event.target as Element).closest('.fkp-dynlist-settings')) {
      return;
    }

    return ui.DynamicList.prototype.handleClick.call(this, event);
  },

  handleKeydown(event: KeyboardEvent) {
    const dl = event.currentTarget as HTMLElement;
    const item = (event.target as Element).closest('.item');
    const isBackspace = event.key === 'Backspace' || event.keyCode === 8;
    const isDelete = event.key === 'Delete' || event.keyCode === 46;

    if (
      !this.options.disabled &&
      item &&
      item.parentNode === dl &&
      (isBackspace || isDelete)
    ) {
      const items = Array.from(dl.children).filter((node) =>
        node.classList.contains('item'),
      );
      const index = items.indexOf(item);
      const nextItem = items[index + (isBackspace ? -1 : 1)];

      if (nextItem) {
        (nextItem as HTMLElement).focus();
      } else if (isDelete) {
        (dl.querySelector('.add-item > *') as HTMLElement | null)?.focus();
      }

      this.removeItem(dl, item);
      event.preventDefault();
      return;
    }

    return ui.DynamicList.prototype.handleKeydown.call(this, event);
  },
});

const ButtonAddSettingsUIDynamicList = SettingsUIDynamicList.extend({
  render() {
    const node = SettingsUIDynamicList.prototype.render.call(this);
    node.classList.add('fkp-button-add-dynlist');

    const input = node.querySelector('.add-item > input[type="text"]');
    input?.remove();
    // LuCI inserts every entry before .add-item, so a list that takes no new entry only hides it.
    node
      .querySelector('.add-item')
      ?.classList.toggle('hidden', this.options.addable === false);

    updateButtonAddDynamicListLayout(node, this.options.addButtonLabel);

    node.addEventListener('cbi-dynlist-change', () => {
      updateButtonAddDynamicListLayout(node, this.options.addButtonLabel);
    });

    // The invalid mark goes onto the list's one control, drawn as a dropdown, so the theme's own
    // invalid-dropdown rule shows it.
    const control = node.querySelector('.add-item > .fkp-button-add-control');
    const showValidity = (invalid: boolean) =>
      control?.classList.toggle('cbi-input-invalid', invalid);
    node.addEventListener('validation-failure', () => showValidity(true));
    node.addEventListener('validation-success', () => showValidity(false));
    showValidity(node.classList.contains('cbi-input-invalid'));

    return node;
  },

  addButtonItem(_dl?: HTMLElement) {
    if (typeof this.options.settingsHandler === 'function') {
      this.options.settingsHandler('', null, this, { adding: true });
    }
  },

  handleClick(event: Event) {
    if (
      !this.options.disabled &&
      (event.target as Element).closest('.add-item > .fkp-button-add-control')
    ) {
      event.preventDefault();
      event.stopPropagation();
      this.addButtonItem(event.currentTarget as HTMLElement);
      return;
    }

    return SettingsUIDynamicList.prototype.handleClick.call(this, event);
  },

  handleKeydown(event: KeyboardEvent) {
    if (
      !this.options.disabled &&
      (event.target as Element).closest(
        '.add-item > .fkp-button-add-control',
      ) &&
      (event.key === 'Enter' || event.key === ' ')
    ) {
      event.preventDefault();
      event.stopPropagation();
      this.addButtonItem(event.currentTarget as HTMLElement);
      return;
    }

    return ui.DynamicList.prototype.handleKeydown.call(this, event);
  },
});

export const SettingsDynamicList = form.DynamicList.extend({
  // ------------------------------------------------ what one entry is called
  //
  // A saved entry is a child section id and shows what that section stores under
  // childValueOption; a draft is its own text, which its dialog may have renamed. A list without
  // childValueOption shows the section id itself.
  inputValueForItem(ownerId: string, value: unknown) {
    if (!this.childType || !this.childValueOption) {
      return `${value || ''}`.trim();
    }

    const inputValue = childItemInputValue(
      ownerId,
      value,
      this.childType,
      this.childValueOption,
      this.ownerOption,
    );
    const staged = childPendingSettingsStore(this, ownerId)[inputValue];
    const renamed = staged ? staged[this.childValueOption] : null;
    return renamed ? `${renamed}` : inputValue;
  },

  stagedChildSettings(ownerId: string, value: unknown) {
    const staged = childPendingSettingsStore(this, ownerId)[
      this.inputValueForItem(ownerId, value)
    ];
    return staged ? Object.assign({}, staged) : null;
  },

  clearStagedChildSettings(ownerId: string) {
    clearChildPendingSettings(this, ownerId);
  },

  childItemOptions(ownerId: string): ChildItemOptions {
    return {
      typeName: this.childType,
      valueOption: this.childValueOption,
      ownerOption: this.ownerOption,
      createId: this.createId,
      defaults: this.childDefaults,
      stagedSettings: (itemValue: unknown) =>
        this.stagedChildSettings!(ownerId, itemValue),
    };
  },

  // The typed entry becomes its section at once and the list holds the id, so two entries may
  // hold the same text.
  createTypedItem(section_id: string, inputValue: string) {
    const ownerId = this.childOwner(section_id);
    return createChildItem(ownerId, this.childItemOptions!(ownerId), inputValue)
      .value;
  },

  // A list whose entry must be well formed first, a subscription address, says so itself.
  hasItemSettings(ownerId: string, value: unknown) {
    return this.inputValueForItem(ownerId, value).length > 0;
  },

  childOwner(section_id: string) {
    return typeof this.childOwnerId === 'function'
      ? `${this.childOwnerId(section_id) || ''}`.trim()
      : section_id;
  },

  parentSection(section_id: string) {
    return typeof this.parentSectionId === 'function'
      ? `${this.parentSectionId(section_id) || ''}`.trim()
      : section_id;
  },

  load(section_id: string) {
    if (this.childType) {
      return getChildItemIds(
        this.childOwner(section_id),
        this.childType,
        this.ownerOption,
      );
    }

    return form.DynamicList.prototype.load.call(this, section_id);
  },

  renderWidget(section_id: string, _option_index: string, cfgvalue: unknown) {
    const value = cfgvalue != null ? cfgvalue : this.default;
    const choices = this.transformChoices();
    const WidgetClass = this.buttonAdd
      ? ButtonAddSettingsUIDynamicList
      : SettingsUIDynamicList;
    const widget = new WidgetClass(L.toArray(value), choices, {
      id: this.cbid(section_id),
      sort: this.keylist,
      allowduplicates: this.allowduplicates,
      optional: this.optional || this.rmempty,
      datatype: this.datatype,
      placeholder: this.placeholder,
      validate: L.bind(this.validate, this, section_id),
      disabled: this.readonly != null ? this.readonly : this.map.readonly,
      addButtonLabel:
        typeof this.addButtonLabel === 'function'
          ? this.addButtonLabel(section_id)
          : this.addButtonLabel,
      addable:
        typeof this.addable === 'function' ? this.addable(section_id) : true,
      settingsHandler: (
        itemValue: string,
        _item: Element | null,
        widget: CBIWidget,
        context: Record<string, unknown>,
      ) => {
        if (typeof this.renderItemSettingsModal === 'function') {
          const ownerId = this.childOwner(section_id);
          this.renderItemSettingsModal(
            ownerId,
            `${itemValue}`,
            this,
            widget,
            _item,
            Object.assign({}, context || {}, {
              parentSectionId: this.parentSection(section_id),
              ownerId,
            }),
          );
        }
      },
      itemLabel: (itemValue: string, text?: string | null) => {
        if (typeof this.renderListItemLabel === 'function') {
          return this.renderListItemLabel(
            this.childOwner(section_id),
            `${itemValue}`,
            text,
          );
        }

        return text;
      },
      hasSettings: (itemValue: string) =>
        this.hasItemSettings!(this.childOwner(section_id), `${itemValue}`),
      createItem:
        this.entriesAreSections && !this.buttonAdd
          ? (inputValue: string) =>
              this.createTypedItem!(section_id, inputValue)
          : null,
      hasEquivalentValue: (itemValue: string, dl: HTMLElement) => {
        const inputValueForItem = (value: unknown) =>
          `${this.inputValueForItem!(this.childOwner(section_id), `${value || ''}`) || ''}`.trim();
        const normalized = inputValueForItem(itemValue);

        return Boolean(
          normalized &&
            dynamicListItemValues(dl).some(
              (existingValue) =>
                inputValueForItem(existingValue) === normalized,
            ),
        );
      },
    });

    const node = widget.render();
    if (typeof this.onListChange === 'function') {
      node.addEventListener('cbi-dynlist-change', () => {
        this.onListChange!(section_id, dynamicListItemValues(node));
      });
    }

    return node;
  },

  // Written on every save: an entry added and taken out again leaves the list as loaded, and
  // only the write deletes its section.
  parse(section_id: string) {
    this.forcewrite = this.entriesAreSections === true;
    if (
      this.isActive(section_id) &&
      typeof this.validateItemsOnSave === 'function'
    ) {
      const result = this.validateItemsOnSave(
        this.childType ? this.childOwner(section_id) : section_id,
        this.formvalue(section_id),
        this,
        section_id,
      );
      if (result !== true) {
        const title = this.stripTags(this.title).trim() || this.option;
        return Promise.reject(new TypeError(`${title}: ${result}`));
      }
    }

    return form.DynamicList.prototype.parse.call(this, section_id);
  },

  write(section_id: string, value: unknown) {
    if (this.childType) {
      const ownerId = this.childOwner(section_id);
      const { itemIds, resolved } = materializeChildItems(
        ownerId,
        this.childItemOptions!(ownerId),
        value,
      );
      adoptMaterializedChildItems(this, section_id, resolved);
      cleanupRemovedChildItems(
        ownerId,
        this.childType,
        itemIds,
        this.ownerOption,
        this.removeNestedChildItems,
      );
      if (typeof this.afterMaterializeChildItems === 'function') {
        this.afterMaterializeChildItems(ownerId, itemIds);
      }
      uci.unset(LOKI_UCI_PACKAGE, section_id, this.option);
      this.clearStagedChildSettings!(ownerId);
      return;
    }

    return form.DynamicList.prototype.write.call(this, section_id, value);
  },

  remove(section_id: string) {
    if (this.childType) {
      // LuCI removes an option the dialog hides, which here would delete the sections behind it.
      // Only a visible list says anything about its items; a hidden one keeps what cannot be typed
      // again (passwords, keys, subscription URLs) for when its field shows again.
      if (this.isActive(section_id)) {
        cleanupRemovedChildItems(
          this.childOwner(section_id),
          this.childType,
          [],
          this.ownerOption,
          this.removeNestedChildItems,
        );
      }
      uci.unset(LOKI_UCI_PACKAGE, section_id, this.option);
      return;
    }

    return form.DynamicList.prototype.remove.call(this, section_id);
  },
});

export const ButtonAddSettingsDynamicList = SettingsDynamicList.extend({
  buttonAdd: true,
});
