import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, realpathSync } from 'node:fs';
import path from 'node:path';

const digest = (body) => createHash('sha256').update(body).digest('hex');
const noticeName = /^(licen[cs]e|notice|copying|copyright|third.party.licen[cs]e)/i;

export function collectNotices(root, moduleIds) {
  const dependencies = realpathSync(path.join(root, 'node_modules'));
  const supplements = JSON.parse(readFileSync(path.join(root, 'licenses/sources.json')));
  for (const name of ['MIT-permission.txt', 'react-remove-scroll-bar-LICENSE.txt', 'flat-color-icons-LICENSE.md']) {
    const source = supplements.supplements?.find((entry) => entry.file === name);
    if (!source || !/^https:\/\/raw\.githubusercontent\.com\/.+\/[0-9a-f]{40}\//.test(source.source)
      || digest(readFileSync(path.join(root, 'licenses', name))) !== source.sha256) {
      throw new Error('Supplemental notice provenance mismatch');
    }
  }
  const packages = new Map();
  const scanned = new Set();
  const declarations = new Set();

  function addPackage(directory) {
    directory = realpathSync(directory);
    if (!directory.startsWith(dependencies + path.sep)) throw new Error('Dependency escapes node_modules');
    if (scanned.has(directory)) return;
    const metadata = readFileSync(path.join(directory, 'package.json'));
    const pkg = JSON.parse(metadata);
    if (!pkg.name || !pkg.version || !['MIT', 'Apache-2.0', '0BSD', 'OFL-1.1'].includes(pkg.license)) {
      throw new Error('Unreviewed dependency license');
    }
    const key = `${pkg.name}@${pkg.version}`;
    const files = readdirSync(directory, { withFileTypes: true })
      .filter((entry) => entry.isFile() && noticeName.test(entry.name))
      .map((entry) => ({ name: entry.name, body: readFileSync(path.join(directory, entry.name)) }));
    if (!files.length) {
      if (key !== 'use-asset@1.0.4' && key !== 'react-remove-scroll-bar@2.3.8') {
        throw new Error('Dependency has no license text');
      }
      // These published archives omit a license file; preserve their original declaration.
      files.push({ name: 'package.json (original declaration)', body: metadata });
      files.push({ name: 'MIT permission text (supplement)', body: readFileSync(path.join(root, 'licenses/MIT-permission.txt')) });
      declarations.add(key);
      if (key === 'react-remove-scroll-bar@2.3.8') {
        files.push({ name: 'LICENSE (upstream supplement, commit 7301c160fda44cb8cf2b9fdfde61efad35736196)', body: readFileSync(path.join(root, 'licenses/react-remove-scroll-bar-LICENSE.txt')) });
      }
    }
    if (pkg.name === 'react-icons') {
      files.push({ name: 'Flat Color Icons upstream license (MIT alternative)', body: readFileSync(path.join(root, 'licenses/flat-color-icons-LICENSE.md')) });
    }
    files.sort((a, b) => a.name.localeCompare(b.name, 'en'));
    const previous = packages.get(key);
    if (previous && (previous.license !== pkg.license || JSON.stringify(previous.files.map(({ name, body }) => [name, digest(body)])) !== JSON.stringify(files.map(({ name, body }) => [name, digest(body)])))) {
      throw new Error('Conflicting dependency notices');
    }
    packages.set(key, { name: pkg.name, version: pkg.version, license: pkg.license, files });
    scanned.add(directory);
  }

  for (const id of new Set(moduleIds)) {
    if (!id.includes('/node_modules/')) continue;
    const filename = id.split('?', 1)[0];
    if (filename.includes('\0') || !path.isAbsolute(filename)) throw new Error('Invalid dependency module');
    let directory = path.dirname(realpathSync(filename));
    if (filename.includes('/react-icons/') && !/\/react-icons\/(fc|lib)\//.test(filename)) {
      throw new Error('Unreviewed react-icons family');
    }
    while (directory.startsWith(dependencies + path.sep)) {
      const manifest = path.join(directory, 'package.json');
      if (existsSync(manifest) && JSON.parse(readFileSync(manifest)).name) break;
      directory = path.dirname(directory);
    }
    addPackage(directory);
  }

  // Sass resolves these CSS/font imports outside the JavaScript module graph.
  const stylesheet = readFileSync(path.join(root, 'src/styles/main.scss'), 'utf8');
  const styles = [...stylesheet.matchAll(/@(?:import|use|forward)\s+([^;]+);/g)]
    .map((match) => /^['"]([^'"]+)['"]$/.exec(match[1])?.[1]);
  const expected = ['@fontsource/inter/latin-400.css', '@fontsource/inter/latin-800.css', '@fontsource/roboto-mono/latin-400.css', 'modern-normalize/modern-normalize.css'];
  if (JSON.stringify(styles.sort()) !== JSON.stringify(expected.sort())) throw new Error('Unreviewed stylesheet imports');
  for (const name of ['@fontsource/inter', '@fontsource/roboto-mono', 'modern-normalize', 'vite', 'rolldown']) {
    addPackage(path.join(dependencies, name));
  }
  const entries = [...packages.values()].sort((a, b) => `${a.name}@${a.version}`.localeCompare(`${b.name}@${b.version}`, 'en'));
  const inventory = {
    schema: 1,
    lock_sha256: digest(readFileSync(path.join(root, 'bun.lock'))),
    supplements,
    declaration_only_archives: [...declarations].sort(),
    packages: entries.map(({ name, version, license, files }) => ({
      name, version, license,
      notices: files.map(({ name, body }) => ({ name, sha256: digest(body) })),
    })),
  };
  const header = 'YACD bundled dependency notices\n\n'
    + 'Package license files are preserved below. Vite and Rolldown notices cover injected runtime helpers; their additional notices are retained as published.\n'
    + 'use-asset 1.0.4 and react-remove-scroll-bar 2.3.8 omit license files in their npm archives. Their original package declarations and author metadata are reproduced with supplemental MIT permission text. The later react-remove-scroll-bar LICENSE is identified separately; it is not represented as a file from the npm archive.\n'
    + 'Only the react-icons Flat Color Icons family is bundled; its upstream license is included in addition to the react-icons notice.\n\n';
  const notices = header + entries.map((pkg) => `===== ${pkg.name}@${pkg.version} (${pkg.license}) =====\n\n`
    + pkg.files.map(({ name, body }) => `--- ${name} ---\n${new TextDecoder('utf-8', { fatal: true }).decode(body)}\n`).join('\n')).join('\n');
  return { notices: notices + '===== End of notices =====\n', inventory: JSON.stringify(inventory, null, 2) + '\n' };
}

export function thirdPartyNotices(root) {
  return {
    name: 'loki-third-party-notices',
    generateBundle(_options, bundle) {
      const modules = Object.values(bundle).filter((entry) => entry.type === 'chunk').flatMap((entry) => entry.moduleIds);
      const result = collectNotices(root, modules);
      this.emitFile({ type: 'asset', fileName: 'THIRD_PARTY_NOTICES.txt', source: result.notices });
      this.emitFile({ type: 'asset', fileName: 'THIRD_PARTY_INVENTORY.json', source: result.inventory });
    },
  };
}

export function verifyBuild(root, deployed = path.resolve(root, '../luci-app-loki/root/usr/share/loki/yacd')) {
  function files(directory) {
    const result = new Map();
    function visit(relative = '') {
      for (const entry of readdirSync(path.join(directory, relative), { withFileTypes: true })) {
        const name = path.join(relative, entry.name);
        if (entry.isDirectory()) visit(name);
        else if (entry.isFile()) result.set(name, digest(readFileSync(path.join(directory, name))));
        else throw new Error('Unexpected bundle object');
      }
    }
    visit();
    return result;
  }
  const built = files(path.join(root, 'public'));
  for (const name of ['THIRD_PARTY_NOTICES.txt', 'THIRD_PARTY_INVENTORY.json']) {
    if (!built.has(name) || built.get(name) !== digest(readFileSync(path.join(root, 'licenses', name)))) {
      throw new Error('Committed dependency notices differ from the build');
    }
    built.delete(name);
  }
  if (JSON.stringify([...built].sort()) !== JSON.stringify([...files(deployed)].sort())) {
    throw new Error('Committed YACD assets differ from the build');
  }
}

if (import.meta.main) verifyBuild(import.meta.dirname);
