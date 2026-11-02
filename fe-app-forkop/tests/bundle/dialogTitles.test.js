import { beforeEach, describe, expect, it } from 'vitest';

import { coreFeatures } from '../lib/coreFeatures.js';
import { createHarness } from '../lib/luciForm.js';

const WG_KEY = 'zz5/p+jwYqPFlg9mWcOP5ad8xXa4XfOOlrzouVD6E1w=';
const WG_PUB = 'AKR8dq2b9o7/cO8d5mAzxvuxRhhw4DXi1pfUC3IPGWo=';
const JSON_OUTBOUND =
  '{"type":"socks","tag":"local","server":"127.0.0.1","server_port":1080}';
const RULE_SET = 'https://example.com/lists/youtube.srs?format=binary';

let harness;

function add(type, sid, values) {
  harness.uci.add('forkop', type, sid);
  Object.assign(harness.store.get(sid), values);
}

beforeEach(() => {
  harness = createHarness();
  harness.bundle.setCoreFeatures(coreFeatures());
  add('section', 'sec', {
    action: 'connection',
    enabled: '1',
    label: 'google',
    outbound_jsons: [JSON_OUTBOUND],
    rule_set: [RULE_SET],
  });
  add('connection_link', 'link1', {
    section: 'sec',
    uri: 'vless://u@a.example:443#us_socks',
    name: 'us_socks',
    order: '0',
  });
  add('subscription_url', 'sub_a', {
    section: 'sec',
    url: 'https://example.com/sub',
    tag: 'sub1',
  });
  add('section_interface', 'iface1', {
    section: 'sec',
    name: 'lan3',
    display_name: 'lan3',
  });
  add('urltest', 'ut1', { section: 'sec', name: 'URLTest #1' });
  add('fallback_group', 'grp1', { section: 'sec', name: 'Fallback #1' });
  add('fallback_level', 'lvl1', {
    group: 'grp1',
    name: 'Group #1',
    order: '0',
  });
  add('tunnel', 'tun1', {
    section: 'sec',
    kind: 'wireguard',
    name: 'wg',
    order: '0',
    private_key: WG_KEY,
    address: ['10.8.1.9/32'],
  });
  add('tunnel_peer', 'peer1', {
    tunnel: 'tun1',
    order: '0',
    address: '203.0.113.1',
    port: '51820',
    public_key: WG_PUB,
    allowed_ips: ['0.0.0.0/0'],
  });
});

function sectionList(name) {
  const map = new harness.form.Map('forkop');
  const grid = map.section(harness.form.GridSection, 'section');
  delete grid.load;
  harness.bundle.createSectionContent(grid);
  return grid.children.find((option) => option.option === name);
}

function dialogList(dialog, name) {
  return dialog.map.children[0].children.find(
    (option) => option.option === name,
  );
}

describe('a dialog under a section is titled by its kind and name', () => {
  it.each([
    ['connection_link', 'link1', 'Server: us_socks'],
    ['subscription_url', 'sub_a', 'Subscription: sub1'],
    ['interfaces', 'iface1', 'Network interface: lan3'],
    ['urltest', 'ut1', 'URLTest: URLTest #1'],
    ['fallback_group', 'grp1', 'Fallback: Fallback #1'],
    ['outbound_jsons', JSON_OUTBOUND, 'JSON outbound: local'],
    ['rule_set', RULE_SET, 'Rule set: youtube.srs'],
  ])('the %s dialog', async (listName, itemId, title) => {
    const dialog = await harness.openDialog(
      sectionList(listName),
      'sec',
      itemId,
    );

    expect(dialog.title).toBe(title);
  });

  it('and so is one inside another item', async () => {
    const group = await harness.openDialog(
      sectionList('fallback_group'),
      'sec',
      'grp1',
    );
    const level = await harness.openDialog(
      dialogList(group, 'fallback_level'),
      'grp1',
      'lvl1',
    );
    expect(level.title).toBe('Server group: Group #1');
  });
});
