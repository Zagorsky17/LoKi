// Regenerates the catalogs in luci-app-loki/po from the `_()` calls in the bundle, keeping
// translations by msgid.

import { execSync } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';

import glob from 'fast-glob';
import { parse } from '@babel/parser';
import traverse from '@babel/traverse';
import * as t from '@babel/types';

const PROJECT_ID = 'LOKI';
const LANGUAGES = ['ru'];
const PLURAL_FORMS = {
  ru: 'nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);',
};
const DEFAULT_PLURAL_FORMS = 'nplurals=2; plural=(n != 1);';
const DEFAULT_IDENTITY = {
  name: 'Loki',
  email: 'ushan0v@users.noreply.github.com',
};

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)));
const repoRoot = path.resolve(projectRoot, '..');
const poRoot = path.join(repoRoot, 'luci-app-loki/po');

function gitIdentity() {
  const read = (key) => {
    try {
      return execSync(`git config ${key}`, {
        stdio: ['ignore', 'pipe', 'ignore'],
      })
        .toString()
        .trim();
    } catch {
      return '';
    }
  };

  const name = read('user.name');
  const email = read('user.email');
  return name && email ? { name, email } : null;
}

// Windows git cannot open a worktree that WSL git added, so there the catalog keeps the author
// it already names.
function catalogIdentity(pot) {
  const match = pot.match(/^"Last-Translator: (.+) <([^>]+)>\\n"$/m);
  return match ? { name: match[1], email: match[2] } : null;
}

function timestamp(now) {
  const local = new Date(now.getTime() - now.getTimezoneOffset() * 60000);
  const date = local.toISOString().replace('T', ' ').slice(0, 16);
  const offset = -now.getTimezoneOffset();
  const sign = offset >= 0 ? '+' : '-';
  const hours = String(Math.floor(Math.abs(offset) / 60)).padStart(2, '0');
  const minutes = String(Math.abs(offset) % 60).padStart(2, '0');
  return `${date}${sign}${hours}${minutes}`;
}

// A LuCI view ends in a bare `return view.extend(...)`, which is a syntax error
// for a module parse. Dropping that final statement keeps the call sites intact.
function stripTrailingReturn(code) {
  return code.replace(/^\s*return\s+[^;]+;\s*$/gm, (match, offset, input) =>
    input.slice(offset + match.length).trim() === '' ? '' : match,
  );
}

async function collectCalls() {
  const files = await glob(
    [
      'src/**/*.ts',
      '../luci-app-loki/htdocs/luci-static/resources/view/loki/**/*.js',
    ],
    {
      cwd: projectRoot,
      ignore: ['**/*.d.ts', '**/*.test.ts', '**/main.js'],
      absolute: true,
    },
  );

  const entries = new Map();

  for (const file of files.sort()) {
    // External globs may keep ../ prefixes that bypass the ignore patterns.
    if (path.basename(file) === 'main.js') continue;
    const relativePath = path.relative(repoRoot, file).replaceAll('\\', '/');
    let ast;
    try {
      ast = parse(stripTrailingReturn(await fs.readFile(file, 'utf8')), {
        sourceType: 'module',
        plugins: file.endsWith('.ts') ? ['typescript'] : [],
      });
    } catch {
      console.warn(`Parse error in ${relativePath}, skipping`);
      continue;
    }

    traverse.default(ast, {
      CallExpression({ node }) {
        if (!t.isIdentifier(node.callee, { name: '_' })) return;
        const [argument] = node.arguments;
        if (!t.isStringLiteral(argument)) return;

        const key = argument.value.trim();
        if (!key) return;

        if (!entries.has(key)) entries.set(key, []);
        entries.get(key).push(`${relativePath}:${node.loc?.start.line ?? '?'}`);
      },
    });
  }

  return [...entries.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, places]) => ({ key, places }));
}

function escapePoString(value) {
  return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function parseTranslations(content) {
  const translations = new Map();
  let msgid = null;

  for (const line of content.split('\n')) {
    if (line.startsWith('msgid ')) msgid = JSON.parse(line.slice(6));
    else if (line.startsWith('msgstr ') && msgid !== null) {
      translations.set(msgid, JSON.parse(line.slice(7)));
      msgid = null;
    }
  }

  return translations;
}

function renderPot(entries, { name, email }, now) {
  const stamp = timestamp(now);
  const header = [
    '# SOME DESCRIPTIVE TITLE.',
    `# Copyright (C) ${now.getFullYear()} THE PACKAGE'S COPYRIGHT HOLDER`,
    `# This file is distributed under the same license as the ${PROJECT_ID} package.`,
    `# ${name} <${email}>, ${now.getFullYear()}.`,
    '#, fuzzy',
    'msgid ""',
    'msgstr ""',
    `"Project-Id-Version: ${PROJECT_ID}\\n"`,
    '"Report-Msgid-Bugs-To: \\n"',
    `"POT-Creation-Date: ${stamp}\\n"`,
    `"PO-Revision-Date: ${stamp}\\n"`,
    `"Last-Translator: ${name} <${email}>\\n"`,
    '"Language-Team: LANGUAGE <LL@li.org>\\n"',
    '"Language: \\n"',
    '"MIME-Version: 1.0\\n"',
    '"Content-Type: text/plain; charset=UTF-8\\n"',
    '"Content-Transfer-Encoding: 8bit\\n"',
    '',
  ].join('\n');

  const body = entries
    .map(({ key, places }) =>
      [
        ...places.map((place) => `#: ${place}`),
        `msgid "${escapePoString(key)}"`,
        'msgstr ""',
        '',
      ].join('\n'),
    )
    .join('\n');

  return `${header}\n${body}`;
}

function renderPo(entries, translations, language, { name }, now) {
  const stamp = timestamp(now);
  const header = [
    `# ${language.toUpperCase()} translations for ${PROJECT_ID} package.`,
    `# Copyright (C) ${now.getFullYear()} THE ${PROJECT_ID} COPYRIGHT HOLDER`,
    `# This file is distributed under the same license as the ${PROJECT_ID} package.`,
    `# ${name}, ${now.getFullYear()}.`,
    '#',
    'msgid ""',
    'msgstr ""',
    `"Project-Id-Version: ${PROJECT_ID}\\n"`,
    '"Report-Msgid-Bugs-To: \\n"',
    `"POT-Creation-Date: ${stamp}\\n"`,
    `"PO-Revision-Date: ${stamp}\\n"`,
    `"Last-Translator: ${name}\\n"`,
    '"Language-Team: none\\n"',
    `"Language: ${language}\\n"`,
    '"MIME-Version: 1.0\\n"',
    '"Content-Type: text/plain; charset=UTF-8\\n"',
    '"Content-Transfer-Encoding: 8bit\\n"',
    `"Plural-Forms: ${PLURAL_FORMS[language] ?? DEFAULT_PLURAL_FORMS}\\n"`,
    '',
  ].join('\n');

  const body = entries
    .map(({ key }) =>
      [
        `msgid "${escapePoString(key)}"`,
        `msgstr "${escapePoString(translations.get(key) ?? '')}"`,
        '',
      ].join('\n'),
    )
    .join('\n');

  return `${header}\n${body}`;
}

const entries = await collectCalls();
const potPath = path.join(poRoot, 'templates', 'loki.pot');
const previousPot = await fs.readFile(potPath, 'utf8').catch(() => '');
const identity =
  gitIdentity() ?? catalogIdentity(previousPot) ?? DEFAULT_IDENTITY;
const now = new Date();

await fs.mkdir(path.dirname(potPath), { recursive: true });
await fs.writeFile(potPath, renderPot(entries, identity, now), 'utf8');
console.log(`${entries.length} strings -> ${path.relative(repoRoot, potPath)}`);

for (const language of LANGUAGES) {
  const poPath = path.join(poRoot, language, 'loki.po');
  const previous = await fs.readFile(poPath, 'utf8').catch(() => '');
  const translations = parseTranslations(previous);
  await fs.mkdir(path.dirname(poPath), { recursive: true });
  await fs.writeFile(
    poPath,
    renderPo(entries, translations, language, identity, now),
    'utf8',
  );

  const translated = entries.filter(({ key }) => translations.get(key)).length;
  console.log(
    `${translated}/${entries.length} translated -> ${path.relative(repoRoot, poPath)}`,
  );
}
