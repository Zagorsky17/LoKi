import { expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { collectNotices, thirdPartyNotices, verifyBuild } from '../third-party-notices.mjs';

function fixture(run: (root: string, dependency: (name: string, version?: string, license?: string, notice?: string | null) => string) => void) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'loki-notices-'));
  const dependency = (name: string, version = '1.0.0', license = 'MIT', notice: string | null = 'Original copyright\r\nPermission text\r\n') => {
    const directory = path.join(root, 'node_modules', name);
    mkdirSync(directory, { recursive: true });
    writeFileSync(path.join(directory, 'package.json'), JSON.stringify({ name, version, license, author: 'Original author' }));
    writeFileSync(path.join(directory, 'index.js'), 'export const value = 1;');
    if (notice !== null) writeFileSync(path.join(directory, 'LICENSE'), notice);
    return path.join(directory, 'index.js');
  };
  try {
    for (const name of ['@fontsource/inter', '@fontsource/roboto-mono', 'modern-normalize', 'vite', 'rolldown']) dependency(name);
    mkdirSync(path.join(root, 'src/styles'), { recursive: true });
    writeFileSync(path.join(root, 'src/styles/main.scss'), [
      '@fontsource/inter/latin-400.css', '@fontsource/inter/latin-800.css',
      '@fontsource/roboto-mono/latin-400.css', 'modern-normalize/modern-normalize.css',
    ].map((name) => `@import '${name}';`).join('\n'));
    writeFileSync(path.join(root, 'bun.lock'), 'locked inputs');
    mkdirSync(path.join(root, 'licenses'));
    writeFileSync(path.join(root, 'licenses/MIT-permission.txt'), 'Supplemental permission text');
    writeFileSync(path.join(root, 'licenses/react-remove-scroll-bar-LICENSE.txt'), 'Later upstream notice');
    writeFileSync(path.join(root, 'licenses/flat-color-icons-LICENSE.md'), 'MIT alternative');
    writeFileSync(path.join(root, 'licenses/sources.json'), JSON.stringify({ supplements:
      ['MIT-permission.txt', 'react-remove-scroll-bar-LICENSE.txt', 'flat-color-icons-LICENSE.md'].map((file) => ({
        file, source: `https://raw.githubusercontent.com/original/source/${'a'.repeat(40)}/LICENSE`,
        sha256: createHash('sha256').update(readFileSync(path.join(root, 'licenses', file))).digest('hex'),
      })),
    }));
    run(root, dependency);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('preserves complete notices, distinct versions and deterministic package order without host paths', () => fixture((root, dependency) => {
  const a = dependency('alpha', '2.0.0', 'Apache-2.0');
  const b = dependency('beta', '1.0.0', '0BSD');
  const first = collectNotices(root, [b, a, a, '\0vite/preload-helper.js']);
  expect(first).toEqual(collectNotices(root, [a, b]));
  expect(first.notices).toContain('Original copyright\r\nPermission text\r\n');
  expect(first.notices.endsWith('===== End of notices =====\n')).toBe(true);
  expect(first.inventory).not.toContain(root);
  expect(JSON.parse(first.inventory).packages.map((pkg: any) => pkg.name)).toContain('alpha');
  for (const name of ['@fontsource/inter', '@fontsource/roboto-mono', 'modern-normalize', 'vite', 'rolldown']) {
    expect(JSON.parse(first.inventory).packages.map((pkg: any) => pkg.name)).toContain(name);
  }
  expect(first.inventory).toContain('Apache-2.0');
  expect(first.inventory).toContain('0BSD');
}));

test('refuses missing or unreviewed terms and dependencies outside the installation', () => fixture((root, dependency) => {
  const unknown = dependency('missing', '1.0.0', 'MIT', null);
  expect(() => collectNotices(root, [unknown])).toThrow('no license text');
  const forbidden = dependency('restricted', '1.0.0', 'UNLICENSED');
  expect(() => collectNotices(root, [forbidden])).toThrow('Unreviewed dependency license');
  const outside = path.join(root, 'outside');
  mkdirSync(outside);
  writeFileSync(path.join(outside, 'index.js'), 'outside');
  symlinkSync(outside, path.join(root, 'node_modules/escape'));
  expect(() => collectNotices(root, [path.join(root, 'node_modules/escape/index.js')])).toThrow('escapes node_modules');
}));

test('preserves metadata for the two exact archives that omit a license without inventing copyright', () => fixture((root, dependency) => {
  const asset = dependency('use-asset', '1.0.4', 'MIT', null);
  const scroll = dependency('react-remove-scroll-bar', '2.3.8', 'MIT', null);
  const result = collectNotices(root, [scroll, asset, scroll]);
  expect(JSON.parse(result.inventory).declaration_only_archives).toEqual(['react-remove-scroll-bar@2.3.8', 'use-asset@1.0.4']);
  expect(result.notices).toContain(readFileSync(path.join(root, 'node_modules/use-asset/package.json'), 'utf8'));
  expect(result.notices).toContain('Later upstream notice');
  dependency('use-asset', '1.0.5', 'MIT', null);
  expect(() => collectNotices(root, [asset])).toThrow('no license text');
}));

test('refuses an unaudited icon family and changed Sass imports', () => fixture((root, dependency) => {
  dependency('react-icons');
  for (const family of ['fc', 'md']) {
    mkdirSync(path.join(root, 'node_modules/react-icons', family));
    writeFileSync(path.join(root, 'node_modules/react-icons', family, 'index.js'), 'icon');
  }
  expect(collectNotices(root, [path.join(root, 'node_modules/react-icons/fc/index.js')]).notices).toContain('MIT alternative');
  expect(() => collectNotices(root, [path.join(root, 'node_modules/react-icons/md/index.js')])).toThrow('Unreviewed react-icons family');
  const sheet = path.join(root, 'src/styles/main.scss');
  writeFileSync(sheet, readFileSync(sheet, 'utf8') + '\n@use "another-package";');
  expect(() => collectNotices(root, [])).toThrow('Unreviewed stylesheet imports');
}));

test('build hook emits only notice assets and leaves executable chunks unchanged', () => fixture((root, dependency) => {
  const id = dependency('alpha');
  const bundle = { 'app.js': { type: 'chunk', moduleIds: [id], code: 'original executable payload' } };
  const before = JSON.stringify(bundle);
  const emitted: any[] = [];
  thirdPartyNotices(root).generateBundle.call({ emitFile: (entry: any) => emitted.push(entry) }, {}, bundle);
  expect(JSON.stringify(bundle)).toBe(before);
  expect(emitted.map((entry) => entry.fileName)).toEqual(['THIRD_PARTY_NOTICES.txt', 'THIRD_PARTY_INVENTORY.json']);
  expect(emitted.every((entry) => entry.type === 'asset')).toBe(true);
}));

test('refuses altered supplemental notices or mutable source references', () => fixture((root) => {
  const file = path.join(root, 'licenses/MIT-permission.txt');
  const original = readFileSync(file);
  writeFileSync(file, 'changed permission');
  expect(() => collectNotices(root, [])).toThrow('Supplemental notice provenance mismatch');
  writeFileSync(file, original);
  const source = path.join(root, 'licenses/sources.json');
  writeFileSync(source, readFileSync(source, 'utf8').replaceAll('a'.repeat(40), 'master'));
  expect(() => collectNotices(root, [])).toThrow('Supplemental notice provenance mismatch');
}));

test('keeps distinct dependency versions and refuses conflicting notices for the same version', () => fixture((root, dependency) => {
  const first = dependency('alpha');
  const nested = dependency('nested/node_modules/alpha', '2.0.0');
  const metadata = path.join(path.dirname(nested), 'package.json');
  writeFileSync(metadata, JSON.stringify({ name: 'alpha', version: '2.0.0', license: 'MIT' }));
  expect(JSON.parse(collectNotices(root, [first, nested]).inventory).packages.filter((pkg: any) => pkg.name === 'alpha').length).toBe(2);
  writeFileSync(metadata, JSON.stringify({ name: 'alpha', version: '1.0.0', license: 'MIT' }));
  writeFileSync(path.join(path.dirname(nested), 'LICENSE'), 'Conflicting notice');
  expect(() => collectNotices(root, [first, nested])).toThrow('Conflicting dependency notices');
}));

test('artifact verification refuses stale notices, changed or extra assets and symlinks', () => fixture((root) => {
  const deployed = path.join(root, 'deployed');
  for (const directory of ['public', 'deployed']) {
    mkdirSync(path.join(root, directory));
    writeFileSync(path.join(root, directory, 'app.js'), 'stable bundle');
  }
  for (const name of ['THIRD_PARTY_NOTICES.txt', 'THIRD_PARTY_INVENTORY.json']) {
    writeFileSync(path.join(root, 'public', name), name);
    writeFileSync(path.join(root, 'licenses', name), name);
  }
  verifyBuild(root, deployed);
  writeFileSync(path.join(root, 'licenses/THIRD_PARTY_NOTICES.txt'), 'stale notice');
  expect(() => verifyBuild(root, deployed)).toThrow('Committed dependency notices differ');
  writeFileSync(path.join(root, 'licenses/THIRD_PARTY_NOTICES.txt'), 'THIRD_PARTY_NOTICES.txt');
  writeFileSync(path.join(deployed, 'app.js'), 'changed bundle');
  expect(() => verifyBuild(root, deployed)).toThrow('Committed YACD assets differ');
  writeFileSync(path.join(deployed, 'app.js'), 'stable bundle');
  writeFileSync(path.join(deployed, 'extra.js'), 'extra payload');
  expect(() => verifyBuild(root, deployed)).toThrow('Committed YACD assets differ');
  rmSync(path.join(deployed, 'extra.js'));
  symlinkSync(path.join(deployed, 'app.js'), path.join(deployed, 'linked.js'));
  expect(() => verifyBuild(root, deployed)).toThrow('Unexpected bundle object');
}));

test('refuses an undecodable license instead of replacing original bytes', () => fixture((root, dependency) => {
  const id = dependency('alpha');
  writeFileSync(path.join(path.dirname(id), 'LICENSE'), new Uint8Array([0xff, 0xfe, 0x41]));
  expect(() => collectNotices(root, [id])).toThrow();
}));

test('Git preserves verbatim notice bytes while keeping the existing text rules', () => fixture((root) => {
  writeFileSync(path.join(root, '.gitattributes'), readFileSync(new URL('../../.gitattributes', import.meta.url)));
  expect(spawnSync('git', ['init', '--quiet'], { cwd: root }).status).toBe(0);
  const notice = 'yacd-loki/licenses/THIRD_PARTY_NOTICES.txt';
  const attributes = spawnSync('git', ['check-attr', 'text', 'whitespace', '--', notice, 'source.ts'], { cwd: root, encoding: 'utf8' });
  expect(attributes.status).toBe(0);
  expect(attributes.stdout).toContain(`${notice}: text: unset`);
  expect(attributes.stdout).toContain(`${notice}: whitespace: unset`);
  expect(attributes.stdout).toContain('source.ts: text: auto');
  expect(attributes.stdout).toContain('source.ts: whitespace: unspecified');
  const bytes = new TextEncoder().encode('Original author\r\n> \r\n');
  const filtered = spawnSync('git', ['-c', 'core.autocrlf=true', 'hash-object', `--path=${notice}`, '--stdin'], { cwd: root, input: bytes, encoding: 'utf8' });
  const raw = spawnSync('git', ['hash-object', '--no-filters', '--stdin'], { cwd: root, input: bytes, encoding: 'utf8' });
  expect(filtered.status).toBe(0);
  expect(raw.status).toBe(0);
  expect(filtered.stdout).toBe(raw.stdout);
}));
