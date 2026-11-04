import { DETOUR_TARGET_ACTIONS, LOKI_UCI_PACKAGE } from '../../../constants';
import { parseCommentAwareListTokens } from '../../cbi/annotatedTextarea';
import { normalizeDynamicListItems } from '../../cbi/listValues';
import { modalOptionFormValue } from '../../cbi/modal';
import { getUciSectionLabel, getUciSectionName } from '../../cbi/uci';
import { CONNECTION_OUTBOUND_SOURCES, ROUTING_ACTIONS } from './constants';

export function missingConnectionOutbound(
  modalMap: CBIMap,
  section_id: string,
) {
  const action = modalOptionFormValue(modalMap, section_id, 'action');
  if (action !== 'connection') {
    return false;
  }

  return !CONNECTION_OUTBOUND_SOURCES.some(
    (optionName: string) =>
      normalizeDynamicListItems(
        modalOptionFormValue(modalMap, section_id, optionName),
      ).length > 0,
  );
}

// A DNS section with no domain and no whole device has nothing to answer; the backend refuses it.
export function missingDnsMatcher(modalMap: CBIMap, section_id: string) {
  if (modalOptionFormValue(modalMap, section_id, 'action') !== 'dns') {
    return false;
  }

  const value = (name: string) =>
    modalOptionFormValue(modalMap, section_id, name);
  return (
    !parseCommentAwareListTokens(value('_dns_destinations')).length &&
    !['community_lists', '_dns_rule_set', 'fully_routed_ips'].some(
      (name) => normalizeDynamicListItems(value(name)).length > 0,
    )
  );
}

// Exists, is not the asking section, is enabled and carries traffic.
function isDetourTargetSection(
  section: UciSectionObject,
  currentSectionId: string,
) {
  const sectionName = getUciSectionName(section);
  const action = ((section && section.action) as string) || '';

  return (
    !!sectionName &&
    sectionName !== currentSectionId &&
    section.enabled !== '0' &&
    DETOUR_TARGET_ACTIONS.includes(action)
  );
}

function getOutboundDetourTargetSections(currentSectionId: string) {
  return (uci.sections(LOKI_UCI_PACKAGE, 'section') || []).filter((section) =>
    isDetourTargetSection(section, currentSectionId),
  );
}

export function refreshOutboundDetourSectionOptionValues(
  option: CBIOption,
  sectionId: string,
) {
  option.keylist = [];
  option.vallist = [];

  getOutboundDetourTargetSections(sectionId).forEach((targetSection) => {
    option.value(
      getUciSectionName(targetSection),
      getUciSectionLabel(targetSection),
    );
  });
}

export function refreshDnsDetourSectionOptionValues(
  option: CBIOption,
  sectionId: string,
) {
  option.keylist = [];
  option.vallist = [];

  (uci.sections(LOKI_UCI_PACKAGE, 'section') || [])
    .filter((section) => isDetourTargetSection(section, sectionId))
    .forEach((targetSection) => {
      option.value(
        getUciSectionName(targetSection),
        getUciSectionLabel(targetSection),
      );
    });
}

export function dependsOnRoutingAction(option: CBIOption) {
  ROUTING_ACTIONS.forEach((action: string) => option.depends('action', action));
  return option;
}

export function dependsOnRuleConditions(option: CBIOption) {
  const routingConditions = [
    'destinations',
    'community_lists',
    'rule_set',
    'ports',
  ];
  ROUTING_ACTIONS.forEach((action: string) =>
    routingConditions.forEach((condition) =>
      option.depends({ action, [condition]: /\S/ }),
    ),
  );
  ['_dns_destinations', 'community_lists', 'rule_set', '_dns_rule_set'].forEach(
    (condition) => option.depends({ action: 'dns', [condition]: /\S/ }),
  );
  return option;
}

export function subscriptionDownloadTargetChoices(section_id: string) {
  return (uci.sections(LOKI_UCI_PACKAGE, 'section') || [])
    .filter((section) => isDetourTargetSection(section, section_id))
    .map((section) => ({
      value: getUciSectionName(section),
      label: getUciSectionLabel(section),
    }));
}
