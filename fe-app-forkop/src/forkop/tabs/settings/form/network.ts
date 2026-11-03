// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
import { validateSubnet } from '../../../../validators/validateSubnet';
import { required } from '../../../cbi/required';
import { wholeNumberField } from '../../../../validators/fields';
import {
  createLocalDeviceDynamicListWidget,
  SYSTEM_DEVICE_VALUE,
} from '../../../cbi/localDevices';

export function addNetworkOptions(section: CBISection) {
  const excludedDevicesOption = section.option(
    form.DynamicList,
    'routing_excluded_ips',
    _('Exclude devices from routing'),
    _(
      'LoKi ignores these devices entirely: their traffic is not routed and their DNS is not captured',
    ),
  );
  excludedDevicesOption.placeholder = _('Device or IP');
  excludedDevicesOption.validate = function (
    _section_id: string,
    value: string,
  ) {
    if (!value || value.length === 0 || value === SYSTEM_DEVICE_VALUE) {
      return true;
    }

    return validateSubnet(value);
  };
  excludedDevicesOption.renderWidget = function (
    section_id,
    _option_index,
    cfgvalue,
  ) {
    return createLocalDeviceDynamicListWidget(this, section_id, cfgvalue);
  };

  let o = section.option(
    widgets.DeviceSelect,
    'source_network_interfaces',
    _('Source Network Interface'),
    _('The interface the traffic comes from'),
  );
  o.default = 'br-lan';
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = true;
  o.filter = function (section_id: string, value: string) {
    const blocked = ['wan', 'phy0-ap0', 'phy1-ap0', 'pppoe-wan'];
    if (blocked.includes(value)) {
      return false;
    }

    // DeviceSelect fills its device list before it calls filter().
    const device = this.devices!.find(
      (dev: NetworkDevice) => dev.getName() === value,
    );

    if (!device) {
      return true;
    }

    const type = device.getType();

    const isWireless =
      type === 'wifi' || type === 'wireless' || type.includes('wlan');

    return !isWireless;
  };

  o = section.option(
    form.Flag,
    'enable_output_network_interface',
    _('Enable Output Network Interface'),
    _("By default the router's routes choose it"),
  );
  o.default = '0';
  o.rmempty = false;

  o = section.option(
    widgets.DeviceSelect,
    'output_network_interface',
    _('Output Network Interface'),
    _('Select the network interface to which the traffic will originate'),
  );
  o.noaliases = true;
  o.multiple = false;
  o.depends('enable_output_network_interface', '1');
  o.filter = function (section_id: string, value: string) {
    const blockedInterfaces = ['br-lan'];

    if (blockedInterfaces.includes(value)) {
      return false;
    }

    if (value.startsWith('lan')) {
      return false;
    }

    if (
      value.startsWith('tun') ||
      value.startsWith('wg') ||
      value.startsWith('vpn') ||
      value.startsWith('awg') ||
      value.startsWith('oc')
    ) {
      return false;
    }

    // DeviceSelect fills its device list before it calls filter().
    const device = this.devices!.find(
      (dev: NetworkDevice) => dev.getName() === value,
    );

    if (!device) {
      return true;
    }

    const type = device.getType();

    const isWireless =
      type === 'wifi' || type === 'wireless' || type.includes('wlan');

    return !isWireless;
  };

  o = section.option(
    form.Flag,
    'enable_badwan_interface_monitoring',
    _('Interface Monitoring'),
    _('Interface monitoring for Bad WAN'),
  );
  o.default = '0';
  o.rmempty = false;

  o = section.option(
    widgets.NetworkSelect,
    'badwan_monitored_interfaces',
    _('Monitored Interfaces'),
    _('Select the WAN interfaces to be monitored'),
  );
  o.depends('enable_badwan_interface_monitoring', '1');
  o.retain = true;
  o.multiple = true;
  o.filter = function (section_id: string, value: string) {
    if (['lan', 'loopback'].includes(value)) {
      return false;
    }

    if (value.startsWith('@')) {
      return false;
    }

    return true;
  };

  o = section.option(
    form.Value,
    'badwan_reload_delay',
    _('Interface Monitoring Delay'),
    _('Delay in milliseconds before reloading LoKi after interface UP'),
  );
  o.depends('enable_badwan_interface_monitoring', '1');
  o.retain = true;
  o.default = '2000';
  o.validate = required(wholeNumberField(0));
}
