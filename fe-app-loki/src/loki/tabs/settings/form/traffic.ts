import { getClashUIUrl } from '../../../../helpers/getClashApiUrl';
import { escapeHtml } from '../../../../helpers/escapeHtml';

export function addTrafficOptions(section: CBISection) {
  let o = section.option(form.DummyValue, '_yacd_link', 'YACD');
  o.rawhtml = true;
  const address = escapeHtml(getClashUIUrl());
  o.cfgvalue = () =>
    `<a href="${address}" target="_blank" rel="noopener noreferrer">${address}</a>`;

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
