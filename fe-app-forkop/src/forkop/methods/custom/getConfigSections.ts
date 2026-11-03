import { Forkop } from '../../types';
import { callUbus } from '../../../helpers/callUbus';
import {
  FORKOP_CALL_TIMEOUT_MS,
  FORKOP_SERVICE_OBJECT,
} from '../../services/forkopWaitTransport';

// The configuration the core runs, which its tags and the Clash API key come from: rpcd lays the
// session's unsaved changes over every uci read of the page.
// The backend refuses a configuration holding a section type ConfigSection does not list.
export async function getConfigSections(): Promise<Forkop.ConfigSection[]> {
  const applied = await callUbus<{ sections: Forkop.ConfigSection[] }>({
    object: FORKOP_SERVICE_OBJECT,
    method:
      typeof L !== 'undefined' && L.hasViewPermission?.() === true
        ? 'config_private'
        : 'config',
    timeoutMs: FORKOP_CALL_TIMEOUT_MS,
    retryUnavailable: false,
  });
  if (applied.success) {
    return applied.data.sections;
  }
  throw new Error(applied.message);
}
