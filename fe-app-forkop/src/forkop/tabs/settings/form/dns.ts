// Modified for LoKi on 2026-10-31: require explicit global DNS encryption and protocol choices.
import {
  configureDnsQueryMode,
  configureDnsServerList,
  offerPublicResolvers,
} from '../../../cbi/dnsServers';
import {
  configureDownloadSectionOption,
  configureDownloadViaProxyFlag,
} from '../sectionChoices';
import { createStaticHostsOption } from '../staticHosts';
import { validateRequiredSingBoxDuration } from '../../../../validators/validateSingBoxDuration';
import { required } from '../../../cbi/required';
import { wholeNumberField } from '../../../../validators/fields';

export function addDnsOptions(section: CBISection) {
  let o = section.option(
    form.ListValue,
    'dns_encryption',
    _('DNS encryption'),
    _(
      'Choose explicitly. Server addresses must match the selected protocol; changing the mode does not rewrite them.',
    ),
  );
  o.value('', _('Choose encryption mode'));
  o.value('0', _('Disabled (UDP)'));
  o.value('1', _('Enabled'));
  o.default = '';
  o.rmempty = false;
  o.validate = required((_sectionId, value) =>
    value === '0' || value === '1' ? true : _('Choose enabled or disabled'),
  );

  o = section.option(
    form.ListValue,
    'dns_encrypted_protocol',
    _('Encrypted DNS protocol'),
  );
  o.value('', _('Choose a protocol'));
  o.value('https', _('DoH (HTTPS)'));
  o.value('tls', _('DoT (TLS)'));
  o.default = '';
  o.rmempty = false;
  o.retain = true;
  o.depends('dns_encryption', '1');
  o.validate = required((_sectionId, value) =>
    value === 'https' || value === 'tls' ? true : _('Choose DoH or DoT'),
  );

  const dnsOption = section.option(
    form.DynamicList,
    'dns_server',
    _('DNS Server'),
    _(
      'All main DNS servers use the selected protocol. Enter https://host/path for DoH, tls://host for DoT, or an IP address for UDP.',
    ),
  );
  dnsOption.default = ['77.88.8.8'];
  offerPublicResolvers(dnsOption);
  configureDnsServerList(dnsOption);
  const validateMainDns = dnsOption.validate;
  dnsOption.validate = function (sectionId, value) {
    const valid = validateMainDns.call(this, sectionId, value);
    if (valid !== true || !value.trim()) return valid;
    const mode = dnsSetting(this, sectionId, 'dns_encryption');
    if (mode !== '0' && mode !== '1') return _('Select a DNS encryption mode');
    const protocol =
      mode === '0'
        ? 'udp'
        : dnsSetting(this, sectionId, 'dns_encrypted_protocol');
    if (mode === '1' && protocol !== 'https' && protocol !== 'tls')
      return _('Choose DoH or DoT');
    return dnsUriProtocol(value) === protocol
      ? true
      : _('The DNS server must use %s').format(protocol);
  };

  o = section.option(
    form.ListValue,
    'dns_main_fallback_strategy',
    _('Main DNS Query Mode'),
    _(
      'Parallel asks every server at once and is faster. Sequential asks them in turn until the first answer',
    ),
  );
  configureDnsQueryMode(o, 'dns_server');

  const bootstrapOption = section.option(
    form.DynamicList,
    'bootstrap_dns_server',
    _('Bootstrap DNS Servers'),
    _(
      'Resolve the addresses of the main DNS servers and proxies over UDP. IP addresses only.',
    ),
  );
  bootstrapOption.default = ['77.88.8.8'];
  offerPublicResolvers(bootstrapOption, { bootstrap: true });
  configureDnsServerList(bootstrapOption, { ipOnly: true });
  const validateBootstrap = bootstrapOption.validate;
  bootstrapOption.validate = function (sectionId, value) {
    const valid = validateBootstrap.call(this, sectionId, value);
    return valid !== true || !value.trim() || dnsUriProtocol(value) === 'udp'
      ? valid
      : _('Bootstrap DNS must use UDP');
  };

  o = section.option(
    form.ListValue,
    'dns_bootstrap_fallback_strategy',
    _('Bootstrap DNS Query Mode'),
    _(
      'Parallel asks every server at once and is faster. Sequential asks them in turn until the first answer',
    ),
  );
  configureDnsQueryMode(o, 'bootstrap_dns_server');

  o = section.option(
    form.Value,
    'dns_rewrite_ttl',
    _('DNS Rewrite TTL'),
    _('How long DNS records are cached, in seconds'),
  );
  o.default = '60';
  o.validate = required(wholeNumberField(0));

  o = section.option(
    form.ListValue,
    'dns_strategy',
    _('DNS Strategy'),
    _('Preferred IP address type for domains'),
  );
  o.value('prefer_ipv4', _('Prefer IPv4'));
  o.value('ipv4_only', _('IPv4 only'));
  o.value('prefer_ipv6', _('Prefer IPv6'));
  o.value('ipv6_only', _('IPv6 only'));
  o.default = 'prefer_ipv4';
  o.rmempty = false;

  o = section.option(
    form.Flag,
    'dns_detour_enabled',
    _('DNS through section'),
    _('Route main DNS requests through a section'),
  );
  configureDownloadViaProxyFlag(o, 'dns_detour_section');

  o = section.option(
    form.ListValue,
    'dns_detour_section',
    _('DNS requests through'),
  );
  o.depends('dns_detour_enabled', '1');
  configureDownloadSectionOption(o, 'dns_detour_section');

  createStaticHostsOption(section);

  o = section.option(
    form.Value,
    'dns_timeout',
    _('DNS timeout'),
    _('Maximum time to wait for a DNS response'),
  );
  o.default = '10s';
  o.validate = (_sectionId: string, value: unknown) =>
    validateRequiredSingBoxDuration(value);

  o = section.option(
    form.ListValue,
    'unmatched_dns_mode',
    _('DNS outside the rules'),
    _('Who resolves domains no rule matched'),
  );
  o.value('forkop', 'Forkop');
  o.value('router', _('Router'));
  o.default = 'forkop';
  o.rmempty = false;
}

function dnsSetting(option: CBIOption, sectionId: string, name: string) {
  const lookup = option.map.lookupOption(name, sectionId);
  return lookup
    ? (lookup[0].formvalue(lookup[1]) ?? lookup[0].cfgvalue(lookup[1]))
    : null;
}

function dnsUriProtocol(value: string) {
  return (
    value
      .trim()
      .match(/^([a-z][a-z0-9+.-]*):\/\//i)?.[1]
      .toLowerCase() || 'udp'
  );
}
