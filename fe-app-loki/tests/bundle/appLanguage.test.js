import { afterEach, expect, it, vi } from 'vitest';

import { createHarness } from '../lib/luciForm.js';

afterEach(() => vi.unstubAllGlobals());

async function settingsLanguage(chosen) {
  const luciCatalog = { aaaaaaaa: 'LuCI language' };
  let browser;
  let document;
  const methods = [];
  const calls = [];
  const harness = createHarness('loki', {
    configureGlobals(globals) {
      browser = globals.window;
      document = globals.document;
      browser.TR = luciCatalog;
      document.documentElement.lang = 'de';
      globals._ = (key) =>
        key === 'LoKi interface language' ? (browser.TR?.aaaaaaaa ?? key) : key;
      globals.L.url = (...parts) => `/${parts.join('/')}`;
      const original = globals.rpc.declare;
      globals.rpc.declare = (args) => {
        methods.push(args.method);
        if (args.method === 'system_info') {
          return async () => {
            calls.push('system_info');
            return {
              available: true,
              system_info: { ui_language: chosen },
            };
          };
        }
        if (args.method === 'state') {
          return async () => ({ capabilities: { core: { known: false } } });
        }
        return original(args);
      };
    },
  });
  const fetchCatalog = vi
    .fn()
    .mockResolvedValue(
      new globalThis.Response('window.TR={"aaaaaaaa":"Язык LoKi",};'),
    );
  vi.stubGlobal('fetch', fetchCatalog);

  await harness.bundle.LokiView.load();
  const map = new harness.form.Map('loki');
  const section = map.section(
    harness.form.TypedSection,
    'settings',
    'Settings',
  );
  harness.bundle.createSettingsContent(section);
  return {
    title: section.children[0].title,
    options: section.children[0].keylist,
    browser,
    document,
    luciCatalog,
    fetchCatalog,
    operations: harness.operations,
    methods,
    calls,
    messages: harness.messages,
  };
}

it.each([
  ['en', 'LoKi interface language', 0],
  ['ru', 'Язык LoKi', 1],
])('keeps LuCI intact when LoKi selects %s', async (chosen, title, loads) => {
  const page = await settingsLanguage(chosen);
  expect(page.calls).toEqual(['system_info']);
  expect(page.messages.some((entry) => entry.includes('[APP_LANGUAGE]'))).toBe(
    false,
  );
  expect(page.fetchCatalog).toHaveBeenCalledTimes(loads);
  expect(page.title).toBe(title);
  expect(page.options).toEqual(['en', 'ru']);
  expect(page.browser.TR).toBe(page.luciCatalog);
  expect(page.document.documentElement.lang).toBe('de');
  expect(page.operations).toEqual([]);
});
