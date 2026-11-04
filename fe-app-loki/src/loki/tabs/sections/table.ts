import { cleanupRemovedChildItems } from '../../cbi/childItems';
import { loadVisibleTableOptions } from '../../cbi/grid';
import { reportRefusedSave, saveSectionModal } from '../../cbi/modal';
import { removeFallbackLevels } from './fallback';
import { forgetOutboundNameChoices } from './outboundNames';
import { missingConnectionOutbound, missingDnsMatcher } from './references';
import { loadDefaultSubscriptionHeaders } from './subscriptions/model';

export function configureSectionSection(sectionRef: CBISection) {
  const handleRemove = sectionRef.handleRemove;
  sectionRef.handleRemove = function (section_id: string, event: Event) {
    cleanupRemovedChildItems(section_id, 'connection_link', []);
    cleanupRemovedChildItems(section_id, 'subscription_url', []);
    cleanupRemovedChildItems(section_id, 'section_interface', []);
    cleanupRemovedChildItems(section_id, 'urltest', []);
    cleanupRemovedChildItems(
      section_id,
      'fallback_group',
      [],
      undefined,
      removeFallbackLevels,
    );
    return handleRemove!.call(this, section_id, event);
  };

  const renderMoreOptionsModal = sectionRef.renderMoreOptionsModal;
  sectionRef.renderMoreOptionsModal = function (
    section_id: string,
    ev?: Event,
  ) {
    forgetOutboundNameChoices();
    return renderMoreOptionsModal.call(this, section_id, ev);
  };

  // Whether a section has servers or something to match spans several fields, so it is checked here,
  // before the dialog writes anything: LuCI parses options one by one, and a refusal halfway leaves
  // the passed fields behind.
  sectionRef.handleModalSave = function (modalMap: CBIMap, ev: Event) {
    // On the modal map LuCI replaces section() with the edited section's id.
    const editedSectionId = modalMap?.section as unknown as string;
    const missing = missingConnectionOutbound(modalMap, editedSectionId)
      ? _('Add a connection URI, subscription, interface or JSON outbound')
      : missingDnsMatcher(modalMap, editedSectionId)
        ? _('Add a domain, built-in list, rule set or device')
        : '';
    if (missing) {
      reportRefusedSave(missing);
      return Promise.resolve(false);
    }

    return saveSectionModal(this, modalMap, ev);
  };

  // The subscription dialog loads the default headers itself when it opens.
  sectionRef.load = function () {
    return Promise.all([
      loadDefaultSubscriptionHeaders().catch((error) => {
        console.warn('[SECTIONS] default subscription headers', error);
        return [];
      }),
      loadVisibleTableOptions(this),
    ]);
  };
}
