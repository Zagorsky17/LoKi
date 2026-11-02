import { beforeEach, describe, expect, it } from 'vitest';

import { coreFeatures } from '../lib/coreFeatures.js';
import { createHarness } from '../lib/luciForm.js';

const WG_PUB = 'AKR8dq2b9o7/cO8d5mAzxvuxRhhw4DXi1pfUC3IPGWo=';

let harness;

function add(type, sid, values) {
  harness.uci.add('forkop', type, sid);
  Object.assign(harness.store.get(sid), values);
}

beforeEach(() => {
  harness = createHarness();
  harness.bundle.setCoreFeatures(coreFeatures());
  add('section', 'sec', { action: 'connection', enabled: '1', label: 'Home' });
  add('connection_link', 'link1', {
    section: 'sec',
    uri: 'vless://u@a.example:443#us',
    name: 'us',
  });
  add('subscription_url', 'sub1', {
    section: 'sec',
    url: 'https://example.com/sub',
    tag: 'sub',
  });
  add('section_interface', 'iface1', { section: 'sec', name: 'lan3' });
  add('urltest', 'ut1', { section: 'sec', name: 'Fast' });
  add('fallback_group', 'grp1', { section: 'sec', name: 'Backup' });
  add('fallback_level', 'lvl1', { group: 'grp1', name: 'First', order: '0' });
  add('tunnel', 'tun1', { section: 'sec', kind: 'wireguard', name: 'wg' });
  add('tunnel_peer', 'peer1', {
    tunnel: 'tun1',
    address: '203.0.113.1',
    port: '51820',
    public_key: WG_PUB,
    allowed_ips: ['0.0.0.0/0'],
  });
  add('settings', 'settings', {});
});

const option = (section, name) =>
  section.children.find((child) => child.option === name);
const fields = (dialog) => dialog.map.children[0];

function grid(type, build) {
  const map = new harness.form.Map('forkop');
  const section = map.section(harness.form.GridSection, type);
  delete section.load;
  build(section);
  return section;
}

async function everyForm() {
  const sections = grid('section', (s) =>
    harness.bundle.createSectionContent(s),
  );
  const settingsMap = new harness.form.Map('forkop');
  const settings = settingsMap.section(harness.form.TypedSection, 'settings');
  settings.cfgsections = () => ['settings'];
  harness.bundle.createSettingsContent(settings);

  const open = (list, owner, item) => harness.openDialog(list, owner, item);
  const tunnel = await open(option(sections, 'tunnels'), 'sec', 'tun1');
  const group = await open(option(sections, 'fallback_group'), 'sec', 'grp1');
  return {
    sections,
    settings,
    link: fields(
      await open(option(sections, 'connection_link'), 'sec', 'link1'),
    ),
    subscription: fields(
      await open(option(sections, 'subscription_url'), 'sec', 'sub1'),
    ),
    interface: fields(
      await open(option(sections, 'interfaces'), 'sec', 'iface1'),
    ),
    urltest: fields(await open(option(sections, 'urltest'), 'sec', 'ut1')),
    fallback: fields(group),
    level: fields(
      await open(option(fields(group), 'fallback_level'), 'grp1', 'lvl1'),
    ),
    tunnel: fields(tunnel),
    peer: fields(
      await open(option(fields(tunnel), 'peer_ids'), 'tun1', 'peer1'),
    ),
  };
}

describe('a field that must not stay empty', () => {
  it('never leaves the refusal to LuCI', async () => {
    const forms = await everyForm();
    const leftToLuci = Object.entries(forms).flatMap(([form, section]) =>
      section.children
        .filter(
          (field) =>
            ['CBI.Value', 'CBI.TextValue'].includes(field.__name__) &&
            field.rmempty === false,
        )
        .map((field) => `${form}: ${field.option}`),
    );

    expect(leftToLuci).toEqual([]);
  });

  it.each([
    ['sections', 'label'],
    ['link', 'name'],
    ['link', 'uri'],
    ['subscription', 'tag'],
    ['subscription', 'url'],
    ['interface', 'display_name'],
    ['urltest', 'name'],
    ['urltest', 'testing_url'],
    ['fallback', 'name'],
    ['level', 'name'],
    ['tunnel', 'name'],
    ['tunnel', 'address'],
    ['tunnel', 'private_key'],
    ['tunnel', 'peer_ids'],
    ['peer', 'address'],
    ['peer', 'port'],
    ['peer', 'public_key'],
    ['peer', 'allowed_ips'],
    ['settings', 'dns_server'],
    ['settings', 'bootstrap_dns_server'],
    ['settings', 'dns_rewrite_ttl'],
  ])('%s %s says it is required', async (form, name) => {
    const forms = await everyForm();
    const field = option(forms[form], name);
    const id = form === 'sections' ? 'sec' : 'settings';
    field.formvalue = () => [];

    expect(field.validate(id, '')).toBe('Required');
  });
});

describe('a value LuCI used to check', () => {
  it('lets a tunnel pick its own local port, and a peer not', async () => {
    const { tunnel, peer } = await everyForm();
    const check = (form, name, value) =>
      option(form, name).validate('settings', value);

    expect(check(tunnel, 'listen_port', '0')).toBe(true);
    expect(check(tunnel, 'warp_port', '0')).toBe(true);
    expect(check(tunnel, 'listen_port', '65536')).toBe('Invalid port');
    expect(check(peer, 'port', '0')).toBe('Invalid port');
  });

  it('says which half of a range is wrong', async () => {
    const { tunnel } = await everyForm();
    const keepalive = (value) =>
      option(tunnel, 'warp_keepalive').validate('settings', value);

    expect(keepalive('25-35')).toBe(true);
    expect(keepalive('35-25')).toBe('The range starts after it ends');
    expect(keepalive('a-b')).toBe('Number or range from 0 to 4294967295');
  });
});
