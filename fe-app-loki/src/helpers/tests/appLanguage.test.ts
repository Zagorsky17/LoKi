import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ getSystemInfo: vi.fn() }));
vi.mock('../../loki/methods', () => ({
  LokiShellMethods: { getSystemInfo: mocks.getSystemInfo },
}));

import { _, loadAppLanguage, pageLanguage } from '../appLanguage';

describe('LoKi page language', () => {
  afterEach(() => vi.unstubAllGlobals());
  beforeEach(() => {
    vi.stubGlobal('window', {
      TR: { aaaaaaaa: 'LuCI translation' },
    });
    vi.stubGlobal('_', (key: string) => window.TR?.aaaaaaaa ?? key);
    vi.stubGlobal('document', { documentElement: { lang: 'de' } });
    vi.stubGlobal('L', {
      url: vi.fn(() => '/cgi-bin/luci/admin/translations/ru'),
    });
    mocks.getSystemInfo.mockReset();
  });

  it('keeps English confined to LoKi while LuCI remains in another language', async () => {
    mocks.getSystemInfo.mockResolvedValue({
      success: true,
      data: { ui_language: 'en' },
    });
    await loadAppLanguage();
    expect(_('Sections')).toBe('Sections');
    expect(pageLanguage()).toBe('en');
    expect(window.TR?.aaaaaaaa).toBe('LuCI translation');
    expect(document.documentElement.lang).toBe('de');
  });

  it('uses the Russian catalog only during LoKi translations', async () => {
    mocks.getSystemInfo.mockResolvedValue({
      success: true,
      data: { ui_language: 'ru' },
    });
    vi.stubGlobal(
      'fetch',
      vi
        .fn()
        .mockResolvedValue(new Response('window.TR={"aaaaaaaa":"Разделы",};')),
    );
    await loadAppLanguage();
    expect(_('Sections')).toBe('Разделы');
    expect(pageLanguage()).toBe('ru');
    expect(window.TR?.aaaaaaaa).toBe('LuCI translation');
    expect(
      (globalThis as typeof globalThis & { _: typeof _ })._('Sections'),
    ).toBe('LuCI translation');
    expect(document.documentElement.lang).toBe('de');
    expect(fetch).toHaveBeenCalledWith('/cgi-bin/luci/admin/translations/ru', {
      credentials: 'same-origin',
    });
  });

  it('restores LuCI translations even when its translator throws', async () => {
    mocks.getSystemInfo.mockResolvedValue({
      success: true,
      data: { ui_language: 'ru' },
    });
    vi.stubGlobal(
      'fetch',
      vi
        .fn()
        .mockResolvedValue(new Response('window.TR={"aaaaaaaa":"Разделы",};')),
    );
    await loadAppLanguage();
    const original = window.TR;
    vi.stubGlobal('_', () => {
      throw new Error('translation failed');
    });
    expect(() => _('Sections')).toThrow('translation failed');
    expect(window.TR).toBe(original);
  });

  it('switches English to Russian and back without retaining the old catalog', async () => {
    for (const ui_language of ['en', 'ru', 'en']) {
      mocks.getSystemInfo.mockResolvedValueOnce({
        success: true,
        data: { ui_language },
      });
    }
    vi.stubGlobal(
      'fetch',
      vi
        .fn()
        .mockResolvedValue(new Response('window.TR={"aaaaaaaa":"Разделы",};')),
    );
    const original = window.TR;
    for (const expected of ['Sections', 'Разделы', 'Sections']) {
      await loadAppLanguage();
      expect(_('Sections')).toBe(expected);
      expect(window.TR).toBe(original);
    }
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it('rejects executable or malformed catalog data and falls back to English', async () => {
    mocks.getSystemInfo.mockResolvedValue({
      success: true,
      data: { ui_language: 'ru' },
    });
    for (const body of [
      'window.TR={};alert(1);',
      'window.TR={"__proto__":"unsafe",};',
      'window.TR=[1];',
      'x'.repeat(4 * 1024 * 1024 + 1),
    ]) {
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body)));
      await expect(loadAppLanguage()).rejects.toThrow();
      expect(_('Sections')).toBe('Sections');
      expect(window.TR?.aaaaaaaa).toBe('LuCI translation');
    }
  });

  it('keeps the page usable when the Russian catalog is absent', async () => {
    mocks.getSystemInfo.mockResolvedValue({
      success: true,
      data: { ui_language: 'ru' },
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(new Response('', { status: 404 })),
    );
    await expect(loadAppLanguage()).rejects.toThrow(
      'Russian LoKi translation is unavailable',
    );
    expect(_('Sections')).toBe('Sections');
    expect(window.TR?.aaaaaaaa).toBe('LuCI translation');
    expect(document.documentElement.lang).toBe('de');
  });

  it('keeps the existing LuCI language when LoKi has no preference', async () => {
    mocks.getSystemInfo.mockResolvedValue({
      success: true,
      data: { ui_language: 'auto' },
    });
    await loadAppLanguage();
    expect(_('Sections')).toBe('LuCI translation');
    expect(pageLanguage()).toBe('de');
  });
});
