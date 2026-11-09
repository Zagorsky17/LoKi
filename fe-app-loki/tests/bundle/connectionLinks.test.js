import { beforeEach, describe, expect, it } from 'vitest';

import { coreFeatures } from '../lib/coreFeatures.js';
import { createHarness } from '../lib/luciForm.js';

let harness;

beforeEach(() => {
  harness = createHarness();
  harness.bundle.setCoreFeatures(coreFeatures());
  harness.uci.add('loki', 'section', 'sec');
  Object.assign(harness.store.get('sec'), {
    action: 'connection',
    enabled: '1',
    label: 'Proxy',
  });
});

function linkList() {
  const map = new harness.form.Map('loki');
  const grid = map.section(harness.form.GridSection, 'section');
  delete grid.load;
  harness.bundle.createSectionContent(grid);
  const option = (name) => grid.children.find((item) => item.option === name);
  for (const name of ['connection_link', 'urltest']) {
    option(name).cfgvalue('sec', option(name).load('sec'));
  }
  return option('connection_link');
}

function paste(list, values, link) {
  const itemId = list.createTypedItem('sec', link);
  const label = list.renderListItemLabel('sec', itemId).textContent;
  values.push(itemId);
  list.onListChange('sec', values.slice());
  return label;
}

function storedLinks() {
  return harness.uci
    .sections('loki', 'connection_link')
    .map(({ section, uri, name, order }) => ({ section, uri, name, order }));
}

describe('a pasted link', () => {
  it('is listed under its own name, a number, or its name and a number', () => {
    const list = linkList();
    const values = [];
    list.formvalue = () => values.slice();

    expect(
      [
        'vless://a@a.example:443#USA',
        'trojan://p@b.example:443',
        'vless://c@c.example:443#USA',
        'vmess://' +
          Buffer.from(
            JSON.stringify({ ps: 'VMess node', add: 'd.example' }),
          ).toString('base64'),
      ].map((link) => paste(list, values, link)),
    ).toEqual(['USA', 'Node #1', 'USA #1', 'VMess node']);
  });

  it('is saved as a link of the section under the name the list shows', async () => {
    const list = linkList();
    const values = [];
    list.formvalue = () => values.slice();
    paste(list, values, 'vless://a@a.example:443#USA');
    paste(list, values, 'trojan://p@b.example:443');

    await list.parse('sec');

    expect(storedLinks()).toEqual([
      {
        section: 'sec',
        uri: 'vless://a@a.example:443#USA',
        name: 'USA',
        order: '0',
      },
      {
        section: 'sec',
        uri: 'trojan://p@b.example:443',
        name: 'Node #1',
        order: '1',
      },
    ]);
  });

  it('pasted twice is two servers told apart by name', async () => {
    const list = linkList();
    const values = [];
    list.formvalue = () => values.slice();
    const link = 'vless://a@a.example:443#USA';

    expect([paste(list, values, link), paste(list, values, link)]).toEqual([
      'USA',
      'USA #1',
    ]);
    await list.parse('sec');

    expect(storedLinks()).toEqual([
      { section: 'sec', uri: link, name: 'USA', order: '0' },
      { section: 'sec', uri: link, name: 'USA #1', order: '1' },
    ]);
  });

  it('takes a name no server or group of the section holds, without a slash', () => {
    harness.uci.add('loki', 'urltest', 'ut1');
    Object.assign(harness.store.get('ut1'), {
      section: 'sec',
      name: 'Fastest',
    });
    const list = linkList();
    const values = [];
    list.formvalue = () => values.slice();

    expect([
      paste(list, values, 'vless://a@a.example:443#Fastest'),
      paste(list, values, 'vless://b@b.example:443#US%2FLA'),
    ]).toEqual(['Fastest #1', 'US／LA']);
  });

  it('takes the name the link carries when the link already in the list was renamed', () => {
    const link = 'vless://a@a.example:443#test1';
    harness.uci.add('loki', 'connection_link', 'link1');
    Object.assign(harness.store.get('link1'), {
      section: 'sec',
      uri: link,
      name: 'test2',
      order: '0',
    });
    const list = linkList();
    const values = ['link1'];
    list.formvalue = () => values.slice();

    expect(paste(list, values, link)).toBe('test1');
  });

  it('typed and saved without being added still gets a name of its own', async () => {
    const list = linkList();
    const values = [];
    paste(list, values, 'vless://a@a.example:443#Same');
    list.formvalue = () => [...values, 'vless://b@b.example:443#Same'];

    await list.parse('sec');

    expect(storedLinks().map((link) => link.name)).toEqual(['Same', 'Same #1']);
  });

  it('takes the name its dialog gave it', async () => {
    const list = linkList();
    const values = [];
    list.formvalue = () => values.slice();
    const link = 'vless://a@a.example:443#USA';
    paste(list, values, link);

    const dialog = await harness.openDialog(list, 'sec', values[0]);
    const fields = dialog.map.children[0].children;
    fields.find((option) => option.option === 'name').formvalue = () =>
      ' New York ';
    expect((await dialog.save()).saved).toBe(true);
    await list.parse('sec');

    expect(storedLinks()).toEqual([
      { section: 'sec', uri: link, name: 'New York', order: '0' },
    ]);
  });

  it('taken out again is gone after the save', async () => {
    harness.uci.add('loki', 'connection_link', 'link1');
    Object.assign(harness.store.get('link1'), {
      section: 'sec',
      uri: 'vless://a@a.example:443#USA',
      name: 'USA',
      order: '0',
    });
    const list = linkList();
    const values = ['link1'];
    list.formvalue = () => values.slice();
    paste(list, values, 'trojan://p@b.example:443#Other');
    values.pop();

    await list.parse('sec');

    expect(storedLinks().map((link) => link.name)).toEqual(['USA']);
  });
});

describe('a stored link', () => {
  beforeEach(() => {
    harness.uci.add('loki', 'connection_link', 'link1');
    Object.assign(harness.store.get('link1'), {
      section: 'sec',
      uri: 'vless://a@a.example:443#USA',
      name: 'USA',
      order: '0',
    });
  });

  it('is listed under its stored name', () => {
    expect(linkList().renderListItemLabel('sec', 'link1').textContent).toBe(
      'USA',
    );
  });

  it('changes its link and its name in its dialog', async () => {
    const list = linkList();
    const dialog = await harness.openDialog(list, 'sec', 'link1');
    const fields = dialog.map.children[0].children;
    const field = (name) => fields.find((option) => option.option === name);
    expect(dialog.map.data.get(dialog.map.config, 'settings', 'uri')).toBe(
      'vless://a@a.example:443#USA',
    );
    expect(field('uri').password, 'the link is shown masked').toBe(true);
    expect(dialog.title).toBe('Server: USA');
    field('uri').formvalue = () => 'trojan://p@b.example:443#Other';
    field('name').formvalue = () => 'Chicago';

    expect((await dialog.save()).saved).toBe(true);
    expect(storedLinks()).toEqual([
      {
        section: 'sec',
        uri: 'trojan://p@b.example:443#Other',
        name: 'Chicago',
        order: '0',
      },
    ]);
  });

  it('refuses an empty link and one the core cannot dial', async () => {
    harness.bundle.setCoreFeatures(coreFeatures({ remove: ['with_quic'] }));
    const dialog = await harness.openDialog(linkList(), 'sec', 'link1');
    const fields = dialog.map.children[0].children;
    const check = (name, value) =>
      fields.find((option) => option.option === name).validate('link1', value);

    expect(check('uri', 'hy2://p@b.example:443#H')).toBe(
      'sing-box is built without with_quic',
    );
    expect(check('uri', ' ')).toBe('Required');
    expect(check('uri', 'https://sub.example.com/api/sub/token')).toBe(
      'Probably a subscription URL: paste it into Subscription',
    );
    expect(check('uri', 'vless://a@a.example:443#USA')).toBe(true);
    expect(check('name', '')).toBe('Required');
  });
});
