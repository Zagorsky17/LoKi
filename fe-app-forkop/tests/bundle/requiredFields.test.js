import { beforeEach, describe, expect, it } from 'vitest';

import { coreFeatures } from '../lib/coreFeatures.js';
import { createHarness } from '../lib/luciForm.js';

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
