import fs from 'fs';
import path from 'path';

import { parse } from '@babel/parser';
import { expect, it } from 'vitest';

import { loadBundle } from '../lib/bundle.js';
import { VIEW_DIR } from '../lib/paths.js';

it('preserves LuCI dependencies and the public view API after compression', () => {
  const source = fs.readFileSync(path.join(VIEW_DIR, 'main.js'), 'utf8');
  const program = parse(source, {
    sourceType: 'script',
    allowReturnOutsideFunction: true,
  }).program;
  expect(
    program.directives
      .map(({ value }) => value.value)
      .filter((value) => value.startsWith('require ')),
  ).toEqual([
    'require baseclass',
    'require dom',
    'require form',
    'require fs',
    'require network',
    'require rpc',
    'require tools.widgets as widgets',
    'require uci',
    'require ui',
  ]);
  const view = loadBundle();
  expect(Object.keys(view).sort()).toEqual([
    'LokiView',
    'configureSectionSection',
    'createSectionContent',
    'createSettingsContent',
    'setCoreFeatures',
  ]);
  expect(typeof view.LokiView).toBe('object');
  for (const name of Object.keys(view).filter((name) => name !== 'LokiView')) {
    expect(typeof view[name], name).toBe('function');
  }
  expect(source).toContain('__COMPILED_VERSION_VARIABLE__');
  expect(source).toContain('Modified for LoKi');
});
