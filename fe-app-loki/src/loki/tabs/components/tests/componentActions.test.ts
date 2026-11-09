import { expect, it, vi } from 'vitest';
import type { InstallerRunState } from '../installerRun';

const mocks = vi.hoisted(() => ({
  change: null as ((state: InstallerRunState) => void) | null,
  buttons: [] as Array<{ text: string; disabled?: boolean }>,
  parts: new Map<string, { replaceChildren: (...nodes: unknown[]) => void }>(),
}));

vi.mock('../../../../icons', async (original) =>
  Object.fromEntries(
    Object.keys(await original()).map((name) => [name, () => ({})]),
  ),
);
vi.mock('../../../../partials', () => ({
  renderButton: (props: { text: string; disabled?: boolean }) => {
    mocks.buttons.push(props);
    return props;
  },
  renderModal: vi.fn(),
}));
vi.mock('../render', () => ({
  pageRoot: {
    querySelector: (id: string) => {
      if (!mocks.parts.has(id)) {
        mocks.parts.set(id, { replaceChildren: vi.fn(), append: vi.fn() });
      }
      return mocks.parts.get(id);
    },
  },
}));
vi.mock('../terminal', () => ({
  createTerminal: () => ({ element: {}, setInput: vi.fn() }),
}));
vi.mock('../installerRun', () => ({
  createInstallerRun: (options: {
    onChange: (state: InstallerRunState) => void;
  }) => {
    mocks.change = options.onChange;
    return { state: {}, setShown: vi.fn() };
  },
}));
vi.mock('../../../services/systemInfo.service', () => ({
  ensureSystemInfo: vi.fn(),
}));

it('offers supported package actions while idle and blocks them during service or installer work', async () => {
  globalThis.E = (() => ({
    replaceChildren: vi.fn(),
    addEventListener: vi.fn(),
  })) as unknown as typeof E;
  globalThis.document = { querySelector: () => null } as unknown as Document;
  const { store } = await import('../../../services/store.service');
  const { initController } = await import('../initController');
  initController();
  const disabled = (label: string) =>
    mocks.buttons.filter((button) => button.text === label).at(-1)?.disabled;
  expect(disabled('Check for updates')).toBe(false);
  expect(disabled('Change the build')).toBe(false);
  expect(disabled('Remove LoKi')).toBe(false);
  expect(disabled('Update LoKi')).toBe(true);

  const available = {
    checkResult: { success: true, available: true },
  } as InstallerRunState;
  mocks.change!(available);
  expect(disabled('Update LoKi')).toBe(false);

  store.set({
    serviceState: {
      ...store.get().serviceState,
      data: { ...store.get().serviceState.data, lokiBusy: 'start' },
    },
  });
  for (const label of [
    'Check for updates',
    'Update LoKi',
    'Change the build',
    'Remove LoKi',
  ]) {
    expect(disabled(label)).toBe(true);
  }
  store.set({
    serviceState: {
      ...store.get().serviceState,
      data: { ...store.get().serviceState.data, lokiBusy: null },
    },
  });
  mocks.change!({ ...available, running: true, action: 'update' });
  expect(disabled('Remove LoKi')).toBe(true);
});
