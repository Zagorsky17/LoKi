// How the page words a value it refuses. A field shows the message beside
// itself, so the message says what is wrong and never names the field:
//
//   Required                  the field is empty and must not be
//   Invalid <kind>            the value is not a <kind>: IP address, port, URL...
//   Format: <sample>          the kind alone does not tell what to type
//   <rule>                    a well-formed value a rule refuses, said as the
//                             rule: "Name already taken", "From 1 to 65535"
//
// No period, no "please", no reason why the rule exists. A rule that spans
// several fields has no field to stand beside, so it is reported on save and
// says what to add: "Add a connection URI, subscription, interface or JSON outbound".
//
// One failure reads the same everywhere, so a wording used in more than one
// place lives here.
export const message = {
  required: () => _('Required'),
  nameTaken: () => _('Name already taken'),
  reservedName: () => _('Reserved name'),
  slashInName: () => _('The / character is not allowed'),
  nameCharacters: () => _('Only letters, digits and . _ -'),
  duplicate: () => _('Duplicate value'),
  invalidIp: () => _('Invalid IP address'),
  invalidSubnet: () => _('Invalid subnet'),
  invalidIpOrSubnet: () => _('Invalid IP address or subnet'),
  invalidDomain: () => _('Invalid domain'),
  invalidHost: () => _('Invalid domain or IP address'),
  invalidPort: () => _('Invalid port'),
  invalidUrl: () => _('Invalid URL'),
  invalidJson: () => _('Invalid JSON object'),
  noTag: () => _('No tag field'),
  invalidRegex: () => _('Invalid regular expression'),
  invalidKey: () => _('Invalid key'),
  invalidUuid: () => _('Invalid UUID'),
  invalidPath: () => _('Invalid path'),
  urlOrPath: () => _('URL or absolute path only'),
  duration: () => _('Format: 30m, 12h, 1d'),
  wholeNumber: (min: number, max: number) =>
    _('Whole number from %d to %d').format(min, max),
  rangeReversed: () => _('The range starts after it ends'),
  numberOrRange: () => _('Number or range from 0 to 4294967295'),
  prefixLength: () => _('Format: 10.0.0.2/24'),
  prefixRange: (min: number, max: number) =>
    _('Prefix length from %d to %d').format(min, max),
  sectionSelf: () => _('Cannot be this section'),
  sectionUnavailable: () => _('Section unavailable'),
  noControlCharacters: () => _('Control characters are not allowed'),
  fixSettings: () => _('Fix the settings'),
  // A problem of one entry of a list, said where the whole list stands.
  item: (name: string, problem: string) =>
    name ? `${name}: ${problem}` : problem,
};
