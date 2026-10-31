// Modified for LoKi on 2026-10-31: allow bounded linting of the full bundle on single-CPU hosts.
import fs from 'fs';
import path from 'path';

import { Linter } from 'eslint';
import { describe, expect, it } from 'vitest';

import { VIEW_DIR } from '../lib/paths.js';

const PROVIDED = [
  'window',
  'document',
  'location',
  'navigator',
  'history',
  'screen',
  'setTimeout',
  'clearTimeout',
  'setInterval',
  'clearInterval',
  'requestAnimationFrame',
  'cancelAnimationFrame',
  'queueMicrotask',
  'console',
  'fetch',
  'URL',
  'URLSearchParams',
  'Blob',
  'File',
  'FileReader',
  'FormData',
  'Headers',
  'Request',
  'Response',
  'AbortController',
  'Event',
  'CustomEvent',
  'MouseEvent',
  'KeyboardEvent',
  'MutationObserver',
  'ResizeObserver',
  'IntersectionObserver',
  'TextEncoder',
  'TextDecoder',
  'WebSocket',
  'Worker',
  'getComputedStyle',
  'matchMedia',
  'atob',
  'btoa',
  'HTMLElement',
  'DecompressionStream',
  'CompressionStream',
  'escape',
  'unescape',
  'alert',
  'confirm',
  'prompt',
  'localStorage',
  'sessionStorage',
  'crypto',
  'performance',
  'structuredClone',
  'Image',
  'L',
  'E',
  '_',
  'N_',
  'cbi_update_table',
  'XHR',
];

const REQUIRE_LINE = /^"require ([A-Za-z0-9_.]+)(?: as ([A-Za-z0-9_]+))?";$/gm;

const views = fs.readdirSync(VIEW_DIR).filter((name) => name.endsWith('.js'));

describe.each(views)('%s', (name) => {
  // ESLint takes more than five seconds to analyze the 1 MB bundle on a single CPU.
  it('reads no name nothing defines', () => {
    const source = fs.readFileSync(path.join(VIEW_DIR, name), 'utf8');
    const injected = [...source.matchAll(REQUIRE_LINE)].map(
      (match) => match[2] || match[1],
    );

    const messages = new Linter().verify(
      `(function () {\n${source}\n});\n`,
      {
        languageOptions: {
          ecmaVersion: 2023,
          sourceType: 'script',
          globals: Object.fromEntries(
            [...PROVIDED, ...injected].map((global) => [global, 'readonly']),
          ),
        },
        linterOptions: { reportUnusedDisableDirectives: false },
        rules: { 'no-undef': 'error' },
      },
      name,
    );

    expect(
      messages
        .map((message) => `${message.line}: ${message.message}`)
        .join('\n'),
    ).toBe('');
  }, 15_000);
});

it('finds the built views at all', () => {
  expect(views).not.toEqual([]);
});
