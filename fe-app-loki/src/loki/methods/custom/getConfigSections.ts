import { Loki } from '../../types';
import { callUbus } from '../../../helpers/callUbus';
import {
  LOKI_CALL_TIMEOUT_MS,
  LOKI_SERVICE_OBJECT,
} from '../../services/lokiWaitTransport';

// The configuration the core runs, which its tags and the Clash API key come from: rpcd lays the
// session's unsaved changes over every uci read of the page.
// The backend refuses a configuration holding a section type ConfigSection does not list.
export async function getConfigSections(): Promise<Loki.ConfigSection[]> {
  const applied = await callUbus<{ sections: Loki.ConfigSection[] }>({
    object: LOKI_SERVICE_OBJECT,
    method:
      typeof L !== 'undefined' && L.hasViewPermission?.() === true
        ? 'config_private'
        : 'config',
    timeoutMs: LOKI_CALL_TIMEOUT_MS,
    retryUnavailable: false,
  });
  if (applied.success) {
    return applied.data.sections;
  }
  throw new Error(applied.message);
}
