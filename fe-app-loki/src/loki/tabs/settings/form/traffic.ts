import { LOKI_UCI_PACKAGE } from '../../../../constants';
import {
  getClashUILoginUrl,
  getClashUIUrl,
} from '../../../../helpers/getClashApiUrl';
import { required } from '../../../cbi/required';
import { currentOptionValue } from '../../sections/subscriptions/model';
import { addGenerateButton, randomHex } from '../../../cbi/generate';

export function addTrafficOptions(section: CBISection) {
  let o = section.option(form.Flag, 'enable_yacd', _('Enable YACD'));
  o.default = '0';
  o.rmempty = false;
  // The link logs in with the saved key, which is known only once the form has loaded.
  const renderWidget = o.renderWidget;
  o.renderWidget = function (
    this: CBIOption,
    sectionId: string,
    optionIndex: string,
    cfgvalue: unknown,
  ) {
    const key = `${uci.get(LOKI_UCI_PACKAGE, sectionId, 'yacd_secret_key') || ''}`;
    const href = getClashUILoginUrl(key).replaceAll('&', '&amp;');
    this.description = `<a href="${href}" target="_blank">${getClashUIUrl()}</a>`;
    return renderWidget.call(this, sectionId, optionIndex, cfgvalue);
  };

  o = section.option(
    form.Flag,
    'enable_yacd_wan_access',
    _('Enable YACD WAN Access'),
    _(
      'Access to YACD from the internet. The port has to be opened in the firewall',
    ),
  );
  o.depends('enable_yacd', '1');
  o.default = '0';
  o.rmempty = false;

  // Unmasked: browsers offer to save any password field on the page as the router's login.
  o = section.option(
    form.Value,
    'yacd_secret_key',
    _('Clash API key'),
    _('YACD and other Clash API clients log in with it'),
  );
  // With access from the WAN the controller listens on every address.
  o.validate = function (this: CBIOption, sectionId: string, value: string) {
    const wanAccess = ['enable_yacd', 'enable_yacd_wan_access'].every(
      (name) => currentOptionValue(this, sectionId, name) === '1',
    );
    return wanAccess ? required().call(this, sectionId, value) : true;
  };
  addGenerateButton(o, () => randomHex(16));

  o = section.option(
    form.Flag,
    'disable_quic',
    _('Disable QUIC'),
    _('Disables QUIC for compatibility and to fix video streaming'),
  );
  o.default = '0';
  o.rmempty = false;

  o = section.option(
    form.Flag,
    'bittorrent_direct',
    _('Torrents directly'),
    _('Send BitTorrent traffic past the proxy'),
  );
  o.default = '0';
  o.rmempty = false;
}
