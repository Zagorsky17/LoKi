import { addDnsOptions } from './form/dns';
import { addNetworkOptions } from './form/network';
import { addServiceOptions } from './form/service';
import { addTrafficOptions } from './form/traffic';
import { addUpdateOptions } from './form/updates';

// The Settings tab is one flat section, so the order below is the order the
// page shows.
export function createSettingsContent(section: CBISection) {
  addDnsOptions(section);
  addNetworkOptions(section);
  addTrafficOptions(section);
  addUpdateOptions(section);
  addServiceOptions(section);
}
