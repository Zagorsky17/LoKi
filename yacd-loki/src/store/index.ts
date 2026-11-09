import {
  initialState as app,
  selectChartStyleIndex,
  updateAppConfig,
  updateCollapsibleIsOpen,
  updateCollapsibleIsOpenBulk,
} from './app';
import { initialState as configs } from './configs';

export const initialState = {
  app: app(),
  configs,
};

export const actions = {
  selectChartStyleIndex,
  updateAppConfig,

  app: {
    updateCollapsibleIsOpen,
    updateCollapsibleIsOpenBulk,
    updateAppConfig,
  },
};
