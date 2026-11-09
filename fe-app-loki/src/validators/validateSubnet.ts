import { message } from './messages';
import { Check } from './types';
import { isIPv4, isIPv6 } from './validateIp';

export function validateSubnet(value: string): Check {
  const [ip, cidr, extra] = value.split('/');

  if (!ip || extra !== undefined || (!isIPv4(ip) && !isIPv6(ip))) {
    return message.invalidIpOrSubnet();
  }

  if ((ip === '0.0.0.0' || ip === '::') && cidr == null) {
    return _('Address %s is not allowed').format(ip);
  }

  if (cidr !== undefined) {
    const maxPrefix = isIPv6(ip) ? 128 : 32;
    if (!/^(?:0|[1-9]\d*)$/.test(cidr) || Number(cidr) > maxPrefix) {
      return message.prefixRange(0, maxPrefix);
    }
  }

  return true;
}
