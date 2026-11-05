import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFileSync } from 'child_process';
import { afterEach, expect, it } from 'vitest';
import { ROOT } from './lib/paths.js';

const temporary = [];
afterEach(() => {
  for (const dir of temporary.splice(0))
    fs.rmSync(dir, { recursive: true, force: true });
});

it('generates catalogs from current sources and ignores a stale shipped bundle', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'loki-locales-'));
  temporary.push(dir);
  const app = path.join(dir, 'fe-app-loki');
  const po = path.join(dir, 'luci-app-loki/po');
  const view = path.join(
    dir,
    'luci-app-loki/htdocs/luci-static/resources/view/loki',
  );
  fs.mkdirSync(path.join(app, 'src'), { recursive: true });
  fs.mkdirSync(path.join(po, 'templates'), { recursive: true });
  fs.mkdirSync(path.join(po, 'ru'), { recursive: true });
  fs.mkdirSync(view, { recursive: true });
  fs.writeFileSync(path.join(app, 'package.json'), '{"type":"module"}');
  fs.symlinkSync(
    path.join(ROOT, 'fe-app-loki/node_modules'),
    path.join(app, 'node_modules'),
  );
  fs.copyFileSync(
    path.join(ROOT, 'fe-app-loki/sync-locales.js'),
    path.join(app, 'sync-locales.js'),
  );
  fs.writeFileSync(
    path.join(app, 'src/current.ts'),
    "export const label = _('Current LoKi string');\n",
  );
  fs.writeFileSync(path.join(view, 'main.js'), "_('Stale bundled string');\n");
  const notices = [
    '# Copyright (C) 2017 Original translation contributors',
    '# Copyright (C) 2023 Additional contributors',
  ];
  fs.writeFileSync(
    path.join(po, 'templates/loki.pot'),
    `${notices.join('\n')}\n`,
  );
  fs.writeFileSync(
    path.join(po, 'ru/loki.po'),
    `${notices.join('\n')}\nmsgid "Current LoKi string"\nmsgstr "Текущая строка"\n`,
  );
  execFileSync(process.execPath, ['sync-locales.js'], {
    cwd: app,
    stdio: 'pipe',
  });
  const template = fs.readFileSync(path.join(po, 'templates/loki.pot'), 'utf8');
  const translated = fs.readFileSync(path.join(po, 'ru/loki.po'), 'utf8');
  expect(template).toContain('Current LoKi string');
  expect(template).not.toContain('Stale bundled string');
  expect(translated).toContain('msgstr "Текущая строка"');
  for (const notice of notices) {
    expect(template, 'original template copyright notice').toContain(notice);
    expect(translated, 'original translation copyright notice').toContain(
      notice,
    );
  }
});
