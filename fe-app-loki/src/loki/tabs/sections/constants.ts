export const RULE_SET_ITEM_SETTINGS_KEY = 'rule_set_settings';

export const ROUTING_ACTIONS = ['connection', 'bypass', 'block'];

export const CONNECTIONS_BLOCKED_INTERFACES = [
  'br-lan',
  'eth0',
  'eth1',
  'wan',
  'phy0-ap0',
  'phy1-ap0',
  'pppoe-wan',
  'lan',
];

// Groups arrange the section's own servers and draw members from these; a section with none of
// them is left out of the runtime, so it is refused on save.
export const CONNECTION_OUTBOUND_SOURCES = [
  'connection_link',
  'subscription_url',
  'interfaces',
  'outbound_jsons',
];
