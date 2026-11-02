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
  const app = path.join(dir, 'fe-app-forkop');
  const po = path.join(dir, 'luci-app-forkop/po');
  const view = path.join(
    dir,
    'luci-app-forkop/htdocs/luci-static/resources/view/forkop',
  );
  fs.mkdirSync(path.join(app, 'src'), { recursive: true });
  fs.mkdirSync(path.join(po, 'templates'), { recursive: true });
  fs.mkdirSync(path.join(po, 'ru'), { recursive: true });
  fs.mkdirSync(view, { recursive: true });
  fs.writeFileSync(path.join(app, 'package.json'), '{"type":"module"}');
  fs.symlinkSync(
    path.join(ROOT, 'fe-app-forkop/node_modules'),
    path.join(app, 'node_modules'),
  );
  fs.copyFileSync(
    path.join(ROOT, 'fe-app-forkop/sync-locales.js'),
    path.join(app, 'sync-locales.js'),
  );
  fs.writeFileSync(
    path.join(app, 'src/current.ts'),
    "export const label = _('Current LoKi string');\n",
  );
  fs.writeFileSync(path.join(view, 'main.js'), "_('Stale bundled string');\n");
  fs.writeFileSync(
    path.join(po, 'ru/forkop.po'),
    'msgid "Current LoKi string"\nmsgstr "Текущая строка"\n',
  );
  execFileSync(process.execPath, ['sync-locales.js'], {
    cwd: app,
    stdio: 'pipe',
  });
  const template = fs.readFileSync(
    path.join(po, 'templates/forkop.pot'),
    'utf8',
  );
  const translated = fs.readFileSync(path.join(po, 'ru/forkop.po'), 'utf8');
  expect(template).toContain('Current LoKi string');
  expect(template).not.toContain('Stale bundled string');
  expect(translated).toContain('msgstr "Текущая строка"');
});
