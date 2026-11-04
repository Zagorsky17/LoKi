import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Loki } from '../../../types';
import {
  AFTER_RUN_MS,
  afterRun,
  createInstallerRun,
  InstallerRunState,
} from '../installerRun';

// The router as the page sees it: a run, its output, and whether its process still answers.
interface Router {
  id: string;
  action: Loki.InstallerAction;
  running: boolean;
  interactive: boolean;
  exit: number | null;
  changed: boolean;
  checkResult?: Loki.UpdateCheckResult | null;
  stopRequested: boolean;
  output: string;
  alive: boolean;
  reachable: boolean;
}

function snapshotOf(router: Router, offset: number): Loki.InstallerSnapshot {
  if (!router.id) {
    return { id: '', running: false };
  }
  const data = router.output.slice(offset);
  return {
    id: router.id,
    action: router.action,
    running: router.running,
    interactive: router.interactive,
    exit: router.exit,
    interrupted: false,
    stop_requested: router.stopRequested,
    changed: router.changed,
    check_result: router.checkResult,
    offset,
    next: offset + data.length,
    data,
  };
}

function setup(partial: Partial<Router> = {}) {
  const router: Router = {
    id: 'r1',
    action: 'update',
    running: true,
    interactive: true,
    exit: null,
    changed: false,
    stopRequested: false,
    output: '',
    alive: true,
    reachable: true,
    ...partial,
  };
  const written: string[] = [];
  const failures: string[] = [];
  const after: string[] = [];
  let state: InstallerRunState | null = null;
  const unreachable = () => Promise.reject(new Error('XHR timed out'));
  const api = {
    start: vi.fn(async () => ({ id: 'r9', started: true })),
    status: vi.fn((offset: number) =>
      router.reachable
        ? Promise.resolve(snapshotOf(router, offset))
        : unreachable(),
    ),
    read: vi.fn((id: string, offset: number) => {
      if (!router.reachable) {
        return unreachable();
      }
      return Promise.resolve(
        router.alive
          ? { snapshot: snapshotOf(router, offset), gone: false }
          : { snapshot: null, gone: true },
      );
    }),
    input: vi.fn(async () => true),
    stop: vi.fn(async () => {
      router.stopRequested = true;
      return true;
    }),
  };
  const run = createInstallerRun({
    api,
    terminal: {
      write: (data) => written.push(data),
      reset: () => written.push('<reset>'),
    },
    lang: () => 'ru',
    onChange: (next) => (state = next),
    onStartFailed: (message) => failures.push(message),
    onAfterRun: (next) => after.push(next),
  });
  return { router, api, run, written, failures, after, state: () => state! };
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe('following a run of install.sh', () => {
  it('reads an idle router once and stops', async () => {
    const page = setup({ id: '' });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(5000);
    expect(page.api.status).toHaveBeenCalledTimes(1);
    expect(page.api.read).not.toHaveBeenCalled();
    expect(page.state()).toMatchObject({
      loaded: true,
      id: '',
      running: false,
    });
  });

  it('shows a run from its start and then only what it adds', async () => {
    const page = setup({ output: 'Установщик\r\n' });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(page.written).toEqual(['<reset>', 'Установщик\r\n']);
    page.router.output += '[*] step\r\n';
    await vi.advanceTimersByTimeAsync(1000);
    expect(page.written).toEqual(['<reset>', 'Установщик\r\n', '[*] step\r\n']);
    expect(page.api.read).toHaveBeenLastCalledWith('r1', 22);
  });

  it('starts over when the router has moved on to another run', async () => {
    const page = setup({ output: 'old' });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    Object.assign(page.router, { id: 'r2', output: 'new run' });
    await vi.advanceTimersByTimeAsync(1000);
    expect(page.written).toEqual(['<reset>', 'old', '<reset>', 'new run']);
  });

  it('learns the end from the CLI once the run has gone, and reloads after packages changed', async () => {
    const page = setup({ output: 'a' });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    Object.assign(page.router, {
      alive: false,
      running: false,
      exit: 0,
      changed: true,
      output: 'a\r\nГотово!',
    });
    await vi.advanceTimersByTimeAsync(1000);
    expect(page.written.join('')).toContain('Готово!');
    expect(page.state()).toMatchObject({
      running: false,
      exit: 0,
      after: 'reload',
    });
    expect(page.after).toEqual([]);
    await vi.advanceTimersByTimeAsync(AFTER_RUN_MS);
    expect(page.after).toEqual(['reload']);
    const calls =
      page.api.status.mock.calls.length + page.api.read.mock.calls.length;
    await vi.advanceTimersByTimeAsync(10000);
    expect(
      page.api.status.mock.calls.length + page.api.read.mock.calls.length,
    ).toBe(calls);
  });

  it('leaves for LuCI once Loki is removed', async () => {
    const page = setup({ action: 'uninstall', interactive: false });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    Object.assign(page.router, { running: false, exit: 0, changed: true });
    await vi.advanceTimersByTimeAsync(1000 + AFTER_RUN_MS);
    expect(page.after).toEqual(['leave']);
  });

  it('keeps the page after a run that changed nothing, and after one that ended before it opened', async () => {
    const page = setup();
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    Object.assign(page.router, { running: false, exit: 1 });
    await vi.advanceTimersByTimeAsync(1000 + AFTER_RUN_MS);
    expect(page.after).toEqual([]);

    const later = setup({ running: false, exit: 0, changed: true });
    later.run.setShown(true);
    await vi.advanceTimersByTimeAsync(1000 + AFTER_RUN_MS);
    expect(later.after).toEqual([]);
    expect(later.state()).toMatchObject({ loaded: true, exit: 0, after: null });
  });

  it('follows a run out of view slowly, so its end still reloads the page', async () => {
    const page = setup();
    page.run.refresh();
    await vi.advanceTimersByTimeAsync(0);
    const reads =
      page.api.read.mock.calls.length + page.api.status.mock.calls.length;
    await vi.advanceTimersByTimeAsync(1900);
    expect(
      page.api.read.mock.calls.length + page.api.status.mock.calls.length,
    ).toBe(reads);
    Object.assign(page.router, { running: false, exit: 0, changed: true });
    await vi.advanceTimersByTimeAsync(2000 + AFTER_RUN_MS);
    expect(page.after).toEqual(['reload']);
  });

  it('starts a run and follows the one the router names', async () => {
    const page = setup({ id: '' });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    Object.assign(page.router, {
      id: 'r9',
      action: 'variant',
      running: true,
      output: 'menu',
    });
    await page.run.start('variant');
    expect(page.api.start).toHaveBeenCalledWith('variant', '', false, 'ru');
    expect(page.state()).toMatchObject({
      id: 'r9',
      action: 'variant',
      running: true,
      interactive: true,
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(page.written.join('')).toContain('menu');
  });

  it('says why a start was refused and stays as it was', async () => {
    const page = setup({ id: '' });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    page.api.start.mockRejectedValueOnce(
      new Error('Another installer run is starting'),
    );
    await page.run.start('update');
    expect(page.failures).toEqual(['Another installer run is starting']);
    expect(page.state()).toMatchObject({ starting: false, running: false });
  });

  it('sends keys to a run that takes them and reads the echo at once', async () => {
    const page = setup({ output: 'Какую сборку установить? [2]: ' });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    page.router.output += '3\r\n';
    const reads = page.api.read.mock.calls.length;
    await page.run.input('3\r');
    expect(page.api.input).toHaveBeenCalledWith('r1', '3\r');
    await vi.advanceTimersByTimeAsync(10);
    expect(page.api.read.mock.calls.length).toBeGreaterThan(reads);
    expect(page.written.join('')).toContain('[2]: 3\r\n');
  });

  it('sends no keys to a removal, which asks nothing', async () => {
    const page = setup({ action: 'uninstall', interactive: false });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    await page.run.input('y\r');
    expect(page.api.input).not.toHaveBeenCalled();
  });

  it('asks the run to stop and says so until it ends', async () => {
    const page = setup();
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    const stopping = page.run.stop();
    expect(page.state()).toMatchObject({ running: true, stopping: true });
    await stopping;
    expect(page.api.stop).toHaveBeenCalledWith('r1');
    await page.run.stop();
    expect(page.api.stop).toHaveBeenCalledTimes(1);
    Object.assign(page.router, {
      running: false,
      exit: 1,
      output: '[!] Прервано, ничего не изменено\r\n',
    });
    await vi.advanceTimersByTimeAsync(500);
    expect(page.state()).toMatchObject({
      running: false,
      exit: 1,
      stopping: true,
    });
    expect(page.after).toEqual([]);
  });

  it('takes back a stop the router refused', async () => {
    const page = setup();
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    page.api.stop.mockResolvedValueOnce(false);
    await page.run.stop();
    await vi.advanceTimersByTimeAsync(500);
    expect(page.state()).toMatchObject({ running: true, stopping: false });
  });

  it('keeps when the run began and ended, and whether it left a log', async () => {
    const page = setup();
    page.api.status.mockImplementation(async (offset: number) => ({
      ...snapshotOf(page.router, offset),
      started_at: 1792767700,
      finished_at: null,
      log: false,
    }));
    page.router.alive = false;
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(page.state()).toMatchObject({
      startedAt: 1792767700,
      finishedAt: null,
      log: false,
    });
    page.api.status.mockImplementation(async (offset: number) => ({
      ...snapshotOf(page.router, offset),
      running: false,
      exit: 0,
      started_at: 1792767700,
      finished_at: 1792767760,
      log: true,
    }));
    await vi.advanceTimersByTimeAsync(500);
    expect(page.state()).toMatchObject({
      running: false,
      finishedAt: 1792767760,
      log: true,
    });
  });

  it('shows a stop asked from the terminal or another page', async () => {
    const page = setup({ stopRequested: true });
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(page.state().stopping).toBe(true);
    await page.run.stop();
    expect(page.api.stop).not.toHaveBeenCalled();
  });

  it('says the router is out of reach only after a while', async () => {
    const page = setup();
    page.run.setShown(true);
    await vi.advanceTimersByTimeAsync(0);
    page.router.reachable = false;
    await vi.advanceTimersByTimeAsync(3000);
    expect(page.state().lost).toBe(false);
    await vi.advanceTimersByTimeAsync(4000);
    expect(page.state().lost).toBe(true);
    page.router.reachable = true;
    await vi.advanceTimersByTimeAsync(500);
    expect(page.state().lost).toBe(false);
  });
});

describe('after a run', () => {
  const base = {
    action: 'update',
    exit: 0,
    changed: false,
  } as InstallerRunState;

  it('reloads when packages changed and leaves when Loki is gone', () => {
    expect(afterRun({ ...base, changed: true })).toBe('reload');
    expect(afterRun({ ...base, exit: 4, changed: true })).toBe('reload');
    expect(afterRun({ ...base, action: 'uninstall' })).toBe('leave');
    expect(
      afterRun({ ...base, action: 'uninstall', exit: 3, changed: true }),
    ).toBe('reload');
    expect(afterRun(base)).toBeNull();
  });
});

it('retains a read-only check result and never reloads even if packages changed elsewhere', async () => {
  const result = {
    schema: 1 as const,
    success: true as const,
    available: true,
    installed: { app: '2.0.0', core: '1.14.4-r3', variant: 'base' },
    latest: { app: '2.0.1', core: '1.14.4-r4' },
  };
  const page = setup({ action: 'check', interactive: false });
  page.run.setShown(true);
  await vi.advanceTimersByTimeAsync(0);
  Object.assign(page.router, {
    running: false,
    exit: 0,
    changed: true,
    checkResult: result,
  });
  await vi.advanceTimersByTimeAsync(5000);
  expect(page.state().checkResult).toEqual(result);
  expect(page.state().after).toBeNull();
  expect(page.after).toEqual([]);
  await page.run.input('y');
  expect(page.api.input).not.toHaveBeenCalled();
  expect(
    afterRun({ ...page.state(), action: 'check', changed: true }),
  ).toBeNull();
});
