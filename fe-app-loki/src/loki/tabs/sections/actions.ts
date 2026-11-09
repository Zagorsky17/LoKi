import { LOKI_UCI_PACKAGE } from '../../../constants';
import { escapeHtml } from '../../../helpers/escapeHtml';
import { missingCoreFeatureNote } from '../../services/coreFeatures.service';
import { sectionMissingCoreFeatures } from './coreSupport';

export function getRuleConfiguredAction(section_id: string) {
  const action = uci.get(LOKI_UCI_PACKAGE, section_id, 'action');
  return action ? `${action}` : null;
}

export function getRuleResolvedAction(section_id: string) {
  return getRuleConfiguredAction(section_id) || 'connection';
}

function getActionOptionLabel(action: string) {
  switch (`${action}`) {
    case 'block':
      return 'Block';
    case 'bypass':
      return 'Bypass';
    case 'connection':
      return 'Connection';
    case 'dns':
      return 'DNS';
    default:
      return `${action}`;
  }
}

export function getRuleActionDisplayValue(section_id: string) {
  return getActionOptionLabel(getRuleResolvedAction(section_id));
}

// Says when the installed core cannot run what the section holds.
export function getRuleActionDisplayMarkup(section_id: string) {
  const label = escapeHtml(getRuleActionDisplayValue(section_id));
  const notes = sectionMissingCoreFeatures(section_id).map((feature) =>
    escapeHtml(missingCoreFeatureNote(feature)),
  );
  return notes.length ? `${label} (${notes.join('; ')})` : label;
}

// A dropdown hands back only its own entries, so the stored action is kept in the list; otherwise
// a retired action would be saved as a Connection with no servers.
export function populateActionOptionValues(
  option: CBIOption,
  currentAction?: unknown,
) {
  delete option.keylist;
  delete option.vallist;

  option.value('connection', getActionOptionLabel('connection'));
  option.value('bypass', 'Bypass');
  option.value('block', 'Block');
  option.value('dns', 'DNS');

  const stored = `${currentAction || ''}`.trim();
  if (stored && !option.keylist!.includes(stored)) {
    option.value(stored, getActionOptionLabel(stored));
  }
}
