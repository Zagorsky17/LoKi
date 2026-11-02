import { FORKOP_LUCI_APP_VERSION, FORKOP_UCI_PACKAGE } from '../../constants';
import { injectGlobalStyles } from '../../helpers/injectGlobalStyles';
import { coreService } from '../services/core.service';
import { loadCoreFeatures } from '../services/coreFeatures.service';
import { ComponentsTab } from '../tabs/components';
import { DashboardTab } from '../tabs/dashboard';
import { DiagnosticTab } from '../tabs/diagnostic';
import { LogsTab } from '../tabs/logs';
import { MonitoringTab } from '../tabs/monitoring';
import { mountTabOption } from '../tabs/mountTab';
import {
  configureSectionSection,
  createSectionContent,
} from '../tabs/sections';
import { createSettingsContent } from '../tabs/settings';
import { configureGridSection } from './gridSection';
import { createPageStatus } from './pageStatus';
import { pageTitle } from './pageTitle';

// A tab that renders itself: one anonymous section holding the node its controller binds to.
function addMountedTab(
  map: CBIMap,
  type: string,
  title: string,
  tab: { render: () => HTMLElement; initController: () => unknown },
) {
  const section = map.section(form.TypedSection, type, title);
  section.anonymous = true;
  section.addremove = false;
  section.cfgsections = function () {
    return [type];
  };
  mountTabOption(section, type, tab);
}

export const ForkopView = {
  // The forms offer only what the installed core can run, so its features load first.
  load() {
    return loadCoreFeatures().catch((error) => {
      console.warn('[CORE_FEATURES]', error);
    });
  },

  async render() {
    injectGlobalStyles();

    const forkopMap = new form.Map(
      FORKOP_UCI_PACKAGE,
      pageTitle(FORKOP_LUCI_APP_VERSION, createPageStatus()),
    );
    forkopMap.tabbed = true;

    const rulesSection = forkopMap.section(
      form.GridSection,
      'section',
      _('Sections'),
      _('Routing rules are checked from top to bottom'),
    );
    configureGridSection(
      rulesSection,
      'section',
      _('Section'),
      _('Add a section'),
    );
    const renderRuleContents = rulesSection.renderContents;
    rulesSection.renderContents = function (...args: unknown[]) {
      const node = renderRuleContents.apply(this, args) as HTMLElement;
      const placeholder = node.querySelector?.('.placeholder em');
      if (placeholder) {
        placeholder.textContent = _('Add a section to configure routing');
      }
      return node;
    };
    configureSectionSection(rulesSection);
    createSectionContent(rulesSection);

    const settingsSection = forkopMap.section(
      form.TypedSection,
      'settings',
      _('Settings'),
    );
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    settingsSection.cfgsections = function () {
      return ['settings'];
    };
    createSettingsContent(settingsSection);

    addMountedTab(forkopMap, 'diagnostic', _('Status'), DiagnosticTab);
    addMountedTab(forkopMap, 'dashboard', _('Dashboard'), DashboardTab);
    addMountedTab(forkopMap, 'monitoring', _('Monitoring'), MonitoringTab);
    addMountedTab(forkopMap, 'logs', _('Logs'), LogsTab);
    addMountedTab(forkopMap, 'components', _('Components'), ComponentsTab);

    const rendered = await forkopMap.render();
    coreService();

    return rendered;
  },
};
