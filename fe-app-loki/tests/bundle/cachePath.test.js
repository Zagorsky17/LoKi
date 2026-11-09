import fs from 'fs';
import path from 'path';
import { beforeEach, describe, expect, it } from 'vitest';

import { ROOT } from '../lib/paths.js';
import { createHarness } from '../lib/luciForm.js';

let harness;
beforeEach(() => {
  harness = createHarness();
  harness.uci.add('loki', 'settings', 'settings');
  harness.operations.length = 0;
});

function cacheOption() {
  const map = new harness.form.Map('loki');
  const section = map.section(harness.form.TypedSection, 'settings');
  section.cfgsections = () => ['settings'];
  harness.bundle.createSettingsContent(section);
  const option = section.children.find(
    (child) => child.option === 'cache_path',
  );
  option.cfgvalue('settings', option.load('settings'));
  return option;
}

describe('private cache path defaults', () => {
  it('uses the shipped UCI default and offers separate private RAM and flash paths', () => {
    const shipped = fs.readFileSync(
      path.join(ROOT, 'loki/files/etc/config/loki'),
      'utf8',
    );
    const configured = shipped.match(/option cache_path '([^']+)'/)[1];
    const option = cacheOption();
    expect(option.default).toBe(configured);
    expect(option.keylist).toContain(configured);
    expect(option.keylist).toHaveLength(2);
    expect(new Set(option.keylist).size).toBe(2);
    for (const value of option.keylist) {
      expect(
        value.startsWith('/tmp/')
          ? path.basename(path.dirname(value))
          : path.basename(path.dirname(path.dirname(value))),
      ).toBe('loki');
      if (value.startsWith('/etc/'))
        expect(path.basename(path.dirname(value))).toBe('cache');
      expect(path.basename(value)).toBe('cache.db');
      expect(option.validate('settings', value)).toBe(true);
    }
    expect(option.keylist.some((value) => value.startsWith('/tmp/'))).toBe(
      true,
    );
    expect(option.keylist.some((value) => value.startsWith('/etc/'))).toBe(
      true,
    );
  });

  it.each(['/tmp/loki-core/cache.db', '/mnt/private/cache.db'])(
    'preserves an explicitly stored path on an unchanged save: %s',
    async (value) => {
      harness.uci.set('loki', 'settings', 'cache_path', value);
      harness.operations.length = 0;
      const option = cacheOption();
      expect(option.formvalue('settings')).toBe(value);
      await option.parse('settings');
      expect(harness.uci.get('loki', 'settings', 'cache_path')).toBe(value);
      expect(harness.operations).toEqual([]);
    },
  );
});
