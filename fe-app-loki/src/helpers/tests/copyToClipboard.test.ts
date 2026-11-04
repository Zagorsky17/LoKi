import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ showToast: vi.fn() }));

vi.mock('../showToast', () => ({ showToast: mocks.showToast }));

import { copyToClipboard } from '../copyToClipboard';

function browser(copies: boolean) {
  vi.stubGlobal('document', {
    createElement: () => ({ value: '', select() {} }),
    body: { appendChild() {}, removeChild() {} },
    execCommand: () => copies,
  });
}

beforeEach(() => {
  mocks.showToast.mockReset();
});

describe('copying to the clipboard', () => {
  it('says it copied when the browser did', () => {
    browser(true);
    copyToClipboard('text');

    expect(mocks.showToast).toHaveBeenCalledWith('Copied', 'success');
  });

  it('says it failed when the browser refused', () => {
    browser(false);
    copyToClipboard('text');

    expect(mocks.showToast).toHaveBeenCalledWith('Failed to copy!', 'error');
  });
});
