import { LOKI_UCI_PACKAGE } from '../../../constants';
import {
  keepUnavailableSectionChoice,
  validateSectionChoice,
} from '../../cbi/choices';

function isDownloadSectionAction(action: unknown) {
  return action === 'connection';
}

function refreshDownloadSectionChoices(option: CBIOption) {
  const sections = option.map?.data?.state?.values?.[LOKI_UCI_PACKAGE] ?? {};

  option.keylist = [];
  option.vallist = [];

  for (const secName in sections) {
    const sec = sections[secName];
    if (
      sec['.type'] === 'section' &&
      sec.enabled !== '0' &&
      isDownloadSectionAction(sec.action)
    ) {
      option.value(secName, sec.label || secName);
    }
  }
}

export function configureDownloadSectionOption(
  option: CBIOption,
  sectionOption: string,
) {
  option.default = '';
  option.rmempty = false;
  option.cfgvalue = function (section_id: string) {
    return uci.get(LOKI_UCI_PACKAGE, section_id, sectionOption) || '';
  };
  option.load = function (section_id: string) {
    refreshDownloadSectionChoices(this);
    const value = this.cfgvalue(section_id);
    keepUnavailableSectionChoice(this, value);
    return value;
  };
  option.write = function (section_id: string, value: string) {
    const normalized = value ? `${value}`.trim() : '';

    if (normalized) {
      uci.set(LOKI_UCI_PACKAGE, section_id, sectionOption, normalized);
    } else {
      uci.unset(LOKI_UCI_PACKAGE, section_id, sectionOption);
    }
  };
  option.remove = function (section_id: string) {
    uci.unset(LOKI_UCI_PACKAGE, section_id, sectionOption);
  };
  option.validate = function (_section_id: string, value: string) {
    return validateSectionChoice(this, value);
  };
}

export function configureDownloadViaProxyFlag(
  option: CBIOption,
  sectionOption: string,
) {
  option.default = '0';
  option.rmempty = false;
  option.write = function (section_id: string, value: unknown) {
    const enabled = value === '1' || value === true;
    uci.set(LOKI_UCI_PACKAGE, section_id, this.option, enabled ? '1' : '0');
    if (!enabled) {
      uci.unset(LOKI_UCI_PACKAGE, section_id, sectionOption);
    }
  };
}
