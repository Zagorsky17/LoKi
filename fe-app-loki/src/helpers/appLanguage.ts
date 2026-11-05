import { LokiShellMethods } from '../loki/methods';

type AppLanguage = 'auto' | 'en' | 'ru';

declare global {
  interface Window {
    TR?: Record<string, string>;
  }
}

let language: AppLanguage = 'auto';
let russianCatalog: Record<string, string> | null = null;
const MAX_CATALOG_BYTES = 4 * 1024 * 1024;

function parseCatalog(source: string): Record<string, string> {
  if (
    source.length > MAX_CATALOG_BYTES ||
    !source.startsWith('window.TR={') ||
    !source.endsWith('};')
  ) {
    throw new Error('Invalid LuCI translation catalog');
  }

  const parsed: unknown = JSON.parse(
    source.slice('window.TR='.length, -1).replace(/,}$/, '}'),
  );
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Invalid LuCI translation catalog');
  }

  const catalog: Record<string, string> = Object.create(null);
  for (const [key, value] of Object.entries(parsed)) {
    if (!/^[0-9a-f]{8}$/.test(key) || typeof value !== 'string') {
      throw new Error('Invalid LuCI translation catalog');
    }
    catalog[key] = value;
  }
  return catalog;
}

async function readCatalog(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) throw new Error('Invalid LuCI translation catalog');
  const decoder = new TextDecoder();
  const chunks: string[] = [];
  let bytes = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_CATALOG_BYTES) {
        await reader.cancel();
        throw new Error('Invalid LuCI translation catalog');
      }
      chunks.push(decoder.decode(value, { stream: true }));
    }
    chunks.push(decoder.decode());
    return chunks.join('');
  } finally {
    reader.releaseLock();
  }
}

export async function loadAppLanguage(): Promise<void> {
  const info = await LokiShellMethods.getSystemInfo();
  const selected = info.success ? info.data.ui_language : undefined;
  language = selected === 'en' || selected === 'ru' ? selected : 'auto';
  russianCatalog = null;
  if (language !== 'ru') return;

  const response = await fetch(L.url('admin', 'translations', 'ru'), {
    credentials: 'same-origin',
  });
  if (!response.ok) throw new Error('Russian LoKi translation is unavailable');
  russianCatalog = parseCatalog(await readCatalog(response));
}

export function pageLanguage(): string | undefined {
  return language === 'auto'
    ? document.documentElement.lang || undefined
    : language;
}

function appTranslate(key: string, context?: string): string {
  if (language === 'en') return key;
  if (language !== 'ru') return _(key, context);
  if (!russianCatalog) return key;

  // LuCI's translator reads window.TR; restore it before any other page code runs.
  const previous = window.TR;
  try {
    window.TR = russianCatalog;
    return _(key, context);
  } finally {
    window.TR = previous;
  }
}

export { appTranslate as _ };
