import { beforeEach, describe, expect, it } from 'vitest';

import { coreFeatures } from '../lib/coreFeatures.js';
import { createHarness } from '../lib/luciForm.js';

let harness;

function add(type, sid, values) {
  harness.uci.add('loki', type, sid);
  Object.assign(harness.store.get(sid), values);
}

beforeEach(() => {
  harness = createHarness();
  harness.bundle.setCoreFeatures(coreFeatures());
  add('section', 'sec', { action: 'connection', enabled: '1', label: 'Proxy' });
  add('section', 'hop', { action: 'connection', enabled: '1', label: 'Hop' });
  add('section', 'off', { action: 'connection', enabled: '0', label: 'Off' });
  add('section', 'dns', { action: 'dns', enabled: '1', label: 'DNS' });
});

function list(name) {
  const map = new harness.form.Map('loki');
  const grid = map.section(harness.form.GridSection, 'section');
  delete grid.load;
  harness.bundle.createSectionContent(grid);
  return grid.children.find((option) => option.option === name);
}

async function open(listName, itemId) {
  const dialog = await harness.openDialog(list(listName), 'sec', itemId);
  const fields = dialog.map.children[0].children;
  const field = (name) => fields.find((option) => option.option === name);
  return {
    field,
    shown: (name) => field(name).isActive('settings'),
    loaded: (name) => field(name).load('settings'),
    set(name, value) {
      field(name).formvalue = () => value;
    },
    save: () => dialog.save(),
  };
}

const ITEMS = [
  [
    'a link',
    'connection_link',
    'connection_link',
    { uri: 'vless://u@a.example:443#A', name: 'A', order: '0' },
  ],
  [
    'a subscription',
    'subscription_url',
    'subscription_url',
    { url: '/etc/loki/sub.txt', tag: 'sub1', server_filter_mode: 'all' },
  ],
];

describe.each(ITEMS)('the cascade of %s', (_label, type, listName, values) => {
  it('is off until a section is chosen, and then goes through it', async () => {
    add(type, 'item', { section: 'sec', ...values });
    const dialog = await open(listName, 'item');
    expect(dialog.loaded('_cascade')).toBe('0');

    dialog.set('_cascade', '1');
    dialog.set('detour_section', 'hop');
    expect((await dialog.save()).saved).toBe(true);

    expect(harness.store.get('item').detour_section).toBe('hop');
    expect(harness.store.get('item')._cascade).toBeUndefined();
    expect(harness.store.get('sec').detour_section).toBeUndefined();
  });

  it('is on for a stored section, and off takes the section away', async () => {
    add(type, 'item', { section: 'sec', ...values, detour_section: 'hop' });
    const dialog = await open(listName, 'item');
    expect(dialog.loaded('_cascade')).toBe('1');

    dialog.set('_cascade', '0');
    expect((await dialog.save()).saved).toBe(true);

    expect(harness.store.get('item').detour_section).toBeUndefined();
  });

  it('offers the other enabled sections that carry traffic', async () => {
    add(type, 'item', { section: 'sec', ...values });
    const dialog = await open(listName, 'item');
    dialog.loaded('detour_section');

    expect(dialog.field('detour_section').keylist).toEqual(['hop']);
    dialog.set('_cascade', '1');
    expect(dialog.field('detour_section').validate('settings', 'sec')).toBe(
      'Cannot be this section',
    );
    expect(dialog.field('detour_section').validate('settings', '')).toBe(
      'Required',
    );
  });
});

it('a pasted link keeps its cascade once the section is saved', async () => {
  const links = list('connection_link');
  const link = 'vless://u@a.example:443#A';
  const itemId = links.createTypedItem('sec', link);
  links.formvalue = () => [itemId];
  const dialog = await harness.openDialog(links, 'sec', itemId);
  const fields = dialog.map.children[0].children;
  const field = (name) => fields.find((option) => option.option === name);
  field('_cascade').formvalue = () => '1';
  field('detour_section').formvalue = () => 'hop';
  expect((await dialog.save()).saved).toBe(true);

  await links.parse('sec');

  const [stored] = harness.uci.sections('loki', 'connection_link');
  expect(stored).toMatchObject({ uri: link, name: 'A', detour_section: 'hop' });
  expect(stored._cascade).toBeUndefined();
});
