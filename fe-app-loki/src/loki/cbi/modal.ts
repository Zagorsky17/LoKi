import {
  applyChildItemSettings,
  childItemInputValue,
  isExistingChildItem,
} from './childItems';
import {
  changedSettings,
  childPendingSettingsStore,
  hasChangedSettings,
  pendingChildSettings,
  readChildSettings,
} from './itemSettings';
import { setDynamicListItemValue } from './listItems';
import { E } from '../../helpers/element';
import { showToast } from '../../helpers/showToast';
import { renderButton } from '../../partials';

// LuCI keeps a refused dialog open and says nothing. A field whose widget checks itself is
// already marked; any other refusal is shown.
export function reportRefusedSave(error: unknown, dialog?: ParentNode | null) {
  if (dialog?.querySelector('.cbi-input-invalid')) {
    return;
  }
  const message = error instanceof Error ? error.message : `${error ?? ''}`;
  showToast(message.trim() || _('Settings not saved'), 'error');
}

// LuCI's section dialog save, with its error dialog off. Answers whether it saved.
export function saveSectionModal(
  sectionRef: CBISection,
  modalMap: CBIMap | CBIModalMap,
  ev: Event,
) {
  const mapNode = sectionRef.getActiveModalMap();
  const activeMap = dom.findClassInstance(mapNode) as CBIMap;
  let saved: Promise<unknown> = activeMap.save(undefined, true);
  for (let map = activeMap.parent; map; map = map.parent) {
    const parent = map;
    saved = saved.then(() => parent.load()).then(() => parent.reset());
  }

  return saved
    .then(() => sectionRef.handleModalCancel(modalMap, ev, true))
    .then(
      () => true,
      (error: unknown) => {
        reportRefusedSave(error, mapNode as ParentNode | null);
        return false;
      },
    );
}

export function modalOptionFormValue(
  modalMap: CBIMap,
  section_id: string,
  optionName: string,
) {
  const lookup =
    modalMap && typeof modalMap.lookupOption === 'function'
      ? modalMap.lookupOption(optionName, section_id)
      : null;

  return lookup ? lookup[0].formvalue(lookup[1]) : null;
}

const SINGLE_FIELD_MODAL_STYLE_ID = 'fkp-single-field-modal-styles';

function cleanFormSectionData(sectionData: unknown): ChildSettings {
  const result: ChildSettings = {};

  Object.entries((sectionData || {}) as ChildSettings).forEach(
    ([key, value]) => {
      if (!key || key.charAt(0) === '.') {
        return;
      }

      result[key] = Array.isArray(value) ? value.slice() : value;
    },
  );

  return result;
}

// The modal heading names the single field, so the row drops its label.
export const SINGLE_FIELD_MODAL_CLASS = 'fkp-single-field-modal';

export function ensureSingleFieldModalStyles() {
  if (
    typeof document === 'undefined' ||
    !document.head ||
    document.getElementById(SINGLE_FIELD_MODAL_STYLE_ID)
  ) {
    return;
  }

  document.head.insertAdjacentHTML(
    'beforeend',
    `<style id="${SINGLE_FIELD_MODAL_STYLE_ID}">
      .${SINGLE_FIELD_MODAL_CLASS} .cbi-value-title {
        display: none;
      }

      .${SINGLE_FIELD_MODAL_CLASS} .cbi-value-field {
        width: 100%;
        max-width: 100%;
        flex: 1 1 auto;
        float: none;
        padding-left: 0;
        margin-left: 0;
      }

      .${SINGLE_FIELD_MODAL_CLASS} .cbi-value {
        margin-bottom: 0;
      }
    </style>`,
  );
}

export function renderStackedJsonSettingsModal(
  title: string,
  map: CBIMap,
  onSave: (settings: ChildSettings) => unknown,
  options: StackedModalOptions = {},
) {
  const modal = document.querySelector('#modal_overlay > .modal.cbi-modal');
  const activeMap = modal ? modal.querySelector('.cbi-map:not(.hidden)') : null;
  const buttonRow = modal ? modal.querySelector('div.button-row') : null;
  const heading = modal ? modal.querySelector('h4') : null;

  if (!modal || !activeMap || !buttonRow || !heading) {
    return Promise.resolve();
  }

  return map.render().then((nodes) => {
    if (options.singleField) {
      ensureSingleFieldModalStyles();
      nodes.classList.add(SINGLE_FIELD_MODAL_CLASS);
    }

    const titleNode = E('span', {}, title ? ` » ${title}` : '');
    const originalButtonClass = buttonRow.getAttribute('class') || '';
    const originalButtonNodes = Array.from(buttonRow.childNodes);
    let closed = false;
    let saveButton: HTMLButtonElement | undefined;

    const restoreButtonRow = () => {
      buttonRow.textContent = '';
      originalButtonNodes.forEach((node) => buttonRow.appendChild(node));
      buttonRow.setAttribute('class', originalButtonClass);
    };

    const close = () => {
      if (closed) {
        return;
      }

      closed = true;

      if (nodes.parentNode) {
        nodes.parentNode.removeChild(nodes);
      }
      if (titleNode.parentNode) {
        titleNode.parentNode.removeChild(titleNode);
      }

      activeMap.classList.remove('hidden');
      restoreButtonRow();
    };

    const save = () => {
      if (saveButton) {
        saveButton.disabled = true;
      }

      return map
        .parse()
        .then(() =>
          Promise.resolve(
            onSave(cleanFormSectionData(map.data.get(map.config, 'settings'))),
          ),
        )
        .then(close)
        .catch((error: unknown) => {
          reportRefusedSave(error, nodes);
          if (saveButton) {
            saveButton.disabled = false;
          }
        });
    };

    buttonRow.textContent = '';
    buttonRow.append(
      // Leaving a stacked dialog puts the parent back rather than closing anything.
      E(
        'button',
        {
          class: 'btn cbi-button',
          click: close,
        },
        _('Back'),
      ),
      ' ',
      ...(() => {
        saveButton = E(
          'button',
          {
            class: 'btn cbi-button cbi-button-positive important',
            click: save,
          },
          options.saveLabel || _('Save'),
        );
        const action = options.secondaryAction;
        // The theme spreads row items apart, so the two buttons are one item that aligns them itself.
        return action
          ? [
              E(
                'span',
                {
                  style: 'display: inline-flex; align-items: center; gap: 4px',
                },
                [
                  renderButton({
                    classNames: ['cbi-button', 'cbi-button-neutral'],
                    icon: action.icon,
                    text: action.label,
                    onClick: () => action.run(save),
                  }),
                  saveButton,
                ],
              ),
            ]
          : [saveButton];
      })(),
    );

    heading.appendChild(titleNode);
    activeMap.classList.add('hidden');
    activeMap.parentNode!.insertBefore(nodes, activeMap.nextElementSibling);
  });
}

export function showChildItemSettingsModal(
  section_id: string,
  itemValue: unknown,
  option: CBIOption,
  settings: ChildItemDialog,
) {
  const value = `${itemValue || ''}`.trim();
  const existing = isExistingChildItem(
    section_id,
    value,
    settings.typeName,
    settings.ownerOption,
  );
  const inputValue = childItemInputValue(
    section_id,
    value,
    settings.typeName,
    settings.valueOption,
    settings.ownerOption,
  );
  const defaults =
    typeof settings.defaults === 'function'
      ? settings.defaults(inputValue, existing)
      : Object.assign({}, settings.defaults || {});
  const initialSettings = existing
    ? readChildSettings(value, settings.keys, defaults)
    : Object.assign(
        {},
        // An item still being added has nothing to restore and takes fresh defaults.
        inputValue
          ? pendingChildSettings(option, section_id, inputValue, defaults)
          : defaults,
      );
  const data = {
    settings: Object.assign({}, initialSettings),
  };
  const map = new form.JSONMap(data);
  const itemSection = map.section(form.NamedSection, 'settings');
  itemSection.anonymous = true;
  itemSection.addremove = false;
  settings.addOptions(itemSection, {
    parentSectionId: () => section_id,
    ownerId: () => value || section_id,
    itemValue: () => inputValue,
    listOption: option,
    validateName: settings.validateName,
  });

  return renderStackedJsonSettingsModal(
    settings.title(inputValue),
    map,
    (nextSettings: ChildSettings) => {
      if (existing) {
        const diff = changedSettings(
          initialSettings,
          nextSettings,
          settings.keys,
        );
        if (hasChangedSettings(diff)) {
          applyChildItemSettings(value, diff);
        }
        if (typeof settings.afterSave === 'function') {
          settings.afterSave(value, inputValue, nextSettings, existing);
        }
        return;
      }

      const nextInputValue =
        `${nextSettings[settings.valueOption ?? ''] || inputValue || ''}`.trim();
      const store = childPendingSettingsStore(option, section_id);
      if (nextInputValue !== inputValue) {
        delete store[inputValue];
        // A draft is identified by its display value, so the list item follows the rename.
        setDynamicListItemValue(settings.itemNode, nextInputValue);
      }
      store[nextInputValue] = nextSettings;
      if (typeof settings.afterSave === 'function') {
        settings.afterSave(value, nextInputValue, nextSettings, existing);
      }
    },
  );
}

export function setModalOptionValue(
  map: CBIMap,
  option: CBIOption,
  value: unknown,
) {
  map.data.set(map.config, 'settings', option.option, value);
  const element =
    typeof option.getUIElement === 'function'
      ? option.getUIElement('settings')
      : null;
  if (element && typeof element.setValue === 'function') {
    element.setValue(value as string | string[] | null);
    element.triggerValidation();
  }
}
