import { getConfigSections } from './getConfigSections';
import {
  closeAllClashApiConnections,
  closeClashApiConnection,
  getClashApiConnections,
  getClashApiConnectionsSummary,
  getClashApiGroupLatency,
  getClashApiProxyExit,
  getClashApiProxyLink,
  getClashApiProxyLatency,
  setClashApiGroupProxy,
  updateClashApiProxyProviders,
  updateClashApiRuleProviders,
} from './clashApi';
import { getDashboardSections } from './getDashboardSections';

export const CustomForkopMethods = {
  getConfigSections,
  getDashboardSections,
  getClashApiConnections,
  getClashApiConnectionsSummary,
  getClashApiGroupLatency,
  getClashApiProxyExit,
  getClashApiProxyLink,
  getClashApiProxyLatency,
  setClashApiGroupProxy,
  updateClashApiProxyProviders,
  updateClashApiRuleProviders,
  closeClashApiConnection,
  closeAllClashApiConnections,
};
