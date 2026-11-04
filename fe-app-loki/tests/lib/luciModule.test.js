import fs from 'fs';
import os from 'os';
import path from 'path';

import { afterEach, expect, it } from 'vitest';

import { createLoader } from './luciModule.js';

const folders = [];

afterEach(() => {
  for (const folder of folders.splice(0)) {
    fs.rmSync(folder, { recursive: true, force: true });
  }
});

it('loads dependencies with aliases after comments and adjacent directives', () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'loki-luci-loader-'));
  folders.push(folder);
  fs.writeFileSync(
    path.join(folder, 'main.js'),
    '// change notice\n"use strict";"require helper as service";return { value: service.read() };',
  );
  fs.writeFileSync(
    path.join(folder, 'helper.js'),
    'return { read: () => "synthetic-value" };',
  );
  expect(createLoader(folder)('main')).toEqual({ value: 'synthetic-value' });
});

it('ignores require-shaped strings in ordinary code and refuses missing dependencies', () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'loki-luci-loader-'));
  folders.push(folder);
  fs.writeFileSync(
    path.join(folder, 'main.js'),
    'const text = "require missing";return { text };',
  );
  expect(createLoader(folder)('main')).toEqual({ text: 'require missing' });
  fs.writeFileSync(
    path.join(folder, 'main.js'),
    '"require missing";return {};',
  );
  expect(() => createLoader(folder)('main')).toThrow(/ENOENT/);
});
