import {
  DEFAULT_LATENCY_TEST_URL,
  LOKI_UCI_PACKAGE,
  LATENCY_TEST_URL_OPTIONS,
} from '../../../../constants';
import { validateRequiredSingBoxDuration } from '../../../../validators/validateSingBoxDuration';
import {
  configureDownloadSectionOption,
  configureDownloadViaProxyFlag,
} from '../sectionChoices';
import { validateUrlField } from '../../../../validators/validateUrl';

export function addUpdateOptions(section: CBISection) {
  let o = section.option(
    form.Flag,
    'list_update_enabled',
    _('Rule set auto update'),
    _('Update remote lists and rule sets on a schedule'),
  );
  o.default = '1';
  o.rmempty = false;

  o = section.option(form.Value, 'update_interval', _('List update interval'));
  o.depends('list_update_enabled', '1');
  o.retain = true;
  o.placeholder = '1d';
  o.default = '1d';
  o.cfgvalue = function (section_id: string) {
    return uci.get(LOKI_UCI_PACKAGE, section_id, 'update_interval') || '1d';
  };
  o.write = function (section_id: string, value: string) {
    const normalized = value ? `${value}`.trim() : '';

    if (normalized.length) {
      uci.set(LOKI_UCI_PACKAGE, section_id, 'update_interval', normalized);
    } else {
      uci.set(LOKI_UCI_PACKAGE, section_id, 'update_interval', '1d');
    }
  };
  o.validate = function (_section_id: string, value: string) {
    return validateRequiredSingBoxDuration(value);
  };

  o = section.option(
    form.Flag,
    'unified_delay',
    _('Accurate latency measurement'),
    _('Includes connection setup and the TLS handshake'),
  );
  o.default = '1';
  o.rmempty = false;

  o = section.option(
    form.Value,
    'latency_test_url',
    _('Latency test URL'),
    _('URL for the shared latency test of section nodes'),
  );
  LATENCY_TEST_URL_OPTIONS.forEach((value: string) => o.value(value));
  o.default =
    DEFAULT_LATENCY_TEST_URL || 'https://www.gstatic.com/generate_204';
  o.validate = function (_section_id: string, value: string) {
    return validateUrlField(value);
  };

  o = section.option(
    form.Flag,
    'download_lists_via_proxy',
    _('Download lists through a section'),
    _(
      'Download the built-in lists and remote rule sets through the selected section',
    ),
  );
  configureDownloadViaProxyFlag(o, 'download_lists_via_proxy_section');

  o = section.option(
    form.ListValue,
    'download_lists_via_proxy_section',
    _('Download lists through'),
  );
  o.depends('download_lists_via_proxy', '1');
  o.retain = true;
  configureDownloadSectionOption(o, 'download_lists_via_proxy_section');
}
