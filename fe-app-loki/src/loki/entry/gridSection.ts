import { LOKI_UCI_PACKAGE } from '../../constants';
import { nextSectionId } from '../cbi/childItems';
import { getRuleEditButtonText } from '../cbi/grid';
import { clearSharedChildPendingSettings } from '../cbi/itemSettings';
import { captureUnsavedUci, restoreUnsavedUci } from '../cbi/unsavedUci';
import type { UnsavedUci } from '../cbi/unsavedUci';
import { E } from '../../helpers/element';
import { nextNumberedName } from '../../helpers/nextNumberedName';

// LuCI's Add control asks for a name first; both grids name a section themselves.
function renderSectionAdd(sectionRef: CBISection, extraClass?: string) {
  const el = E('div', { class: 'cbi-section-create' });
  const buttonTitle = sectionRef.titleFn('addbtntitle') || _('Add');
  const button = E(
    'button',
    {
      class: 'cbi-button cbi-button-add',
      title: buttonTitle,
      click: ui.createHandlerFn(sectionRef, 'handleAdd'),
      disabled: sectionRef.map.readonly || null,
    },
    [buttonTitle],
  );

  if (extraClass) {
    el.classList.add(extraClass);
  }

  el.appendChild(button);

  return el;
}

// A server and a section may not share a name, so the label is numbered past both.
function nextLabel(sectionRef: CBISection, configName: string, prefix: string) {
  return nextNumberedName(
    prefix,
    ['server', 'section'].flatMap((type) =>
      (sectionRef.map.data.sections(configName, type) || []).map(
        (section) => `${section.label || ''}`,
      ),
    ),
  );
}

export function addLabeledSection(sectionRef: CBISection) {
  const configName = sectionRef.uciconfig || sectionRef.map.config;
  const prefix = sectionRef.sectiontype === 'section' ? 'Section' : 'Server';
  const label = nextLabel(sectionRef, configName, prefix);
  const sectionId = sectionRef.map.data.add(
    configName,
    sectionRef.sectiontype,
    nextSectionId(sectionRef.sectiontype),
  );

  sectionRef.map.data.set(configName, sectionId, 'label', label);
  return sectionId;
}

export function configureGridSection(
  sectionRef: CBISection,
  type: string,
  title: string,
  addTitle: string,
  // Written into a new section before its dialog opens; the Servers tab seeds a protocol.
  onSectionAdded?: (sectionId: string) => void,
) {
  sectionRef.anonymous = false;
  sectionRef.addremove = true;
  sectionRef.sortable = true;
  sectionRef.rowcolors = true;
  sectionRef.nodescriptions = true;
  sectionRef.modaltitle = function (section_id: string) {
    const label = uci.get(LOKI_UCI_PACKAGE, section_id, 'label');
    return section_id ? `${title}: ${label || section_id}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id: string) {
    return uci.get(LOKI_UCI_PACKAGE, section_id, 'label') || section_id;
  };
  sectionRef.renderSectionAdd = function (extraClass?: string) {
    return renderSectionAdd(sectionRef, extraClass);
  };
  // LuCI reports a dialog that fails to open and leaves the new section for the next save to write
  // out empty, so it is taken back.
  sectionRef.handleAdd = function () {
    const sectionId = addLabeledSection(this);
    const mapNode = this.getPreviousModalMap();
    const prevMap = (
      mapNode ? dom.findClassInstance(mapNode) : this.map
    ) as CBIMap;

    prevMap.addedSection = sectionId;
    onSectionAdded?.(sectionId);
    return this.renderMoreOptionsModal(sectionId).catch((error: unknown) => {
      this.map.data.remove(this.uciconfig || this.map.config, sectionId);
      delete prevMap.addedSection;
      throw error;
    });
  };

  // Nested dialogs write into uci as they close, and a refused save keeps the options that passed;
  // dismissing the dialog restores uci as it was when it opened.
  let unsaved: UnsavedUci | null = null;
  sectionRef.renderMoreOptionsModal = function (
    section_id: string,
    ev?: Event,
  ) {
    unsaved = captureUnsavedUci();
    return form.GridSection.prototype.renderMoreOptionsModal.call(
      this,
      section_id,
      ev,
    );
  };
  sectionRef.handleModalCancel = function (
    modalMap: unknown,
    ev: Event,
    isSaving?: boolean,
  ) {
    if (!isSaving && unsaved) {
      restoreUnsavedUci(unsaved);
    }
    unsaved = null;
    clearSharedChildPendingSettings();
    return form.GridSection.prototype.handleModalCancel.call(
      this,
      modalMap,
      ev,
      isSaving,
    );
  };

  if (type === 'section') {
    sectionRef.renderRowActions = function (section_id: string) {
      return form.TableSection.prototype.renderRowActions.call(
        this,
        section_id,
        getRuleEditButtonText(),
      );
    };
  }
}
