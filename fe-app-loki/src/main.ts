'use strict';
'require baseclass';
'require dom';
'require form';
'require fs';
'require network';
'require rpc';
'require tools.widgets as widgets';
'require uci';
'require ui';

import './helpers/structuredClonePolyfill';

// view/loki/loki.js hands this to view.extend().
export { LokiView } from './loki/entry';

// The tab builders, which the bundle checks use to build one tab at a time.
export {
  configureSectionSection,
  createSectionContent,
} from './loki/tabs/sections';
export { createSettingsContent } from './loki/tabs/settings';
// A check building one tab sets the core features the way LokiView reads them.
export { setCoreFeatures } from './loki/services/coreFeatures.service';
