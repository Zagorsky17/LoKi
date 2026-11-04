import { beforeAll, describe, expect, it } from 'vitest';
import { getServiceStatusDisplay } from '../serviceStatusDisplay';

beforeAll(() => {
  (globalThis as unknown as { _: (value: string) => string })._ = (value) =>
    value;
});

describe('service status display', () => {
  it('reports running and stopped when nothing is in flight', () => {
    expect(getServiceStatusDisplay({ running: true, busy: null })).toEqual({
      label: 'running',
      tone: 'success',
    });
    expect(getServiceStatusDisplay({ running: false, busy: null })).toEqual({
      label: 'stopped',
      tone: 'error',
    });
  });

  it('reports the operation instead of a readiness that is momentarily meaningless', () => {
    expect(getServiceStatusDisplay({ running: false, busy: 'apply' })).toEqual({
      label: 'applying...',
      tone: 'progress',
    });
    expect(getServiceStatusDisplay({ running: true, busy: 'apply' })).toEqual({
      label: 'applying...',
      tone: 'progress',
    });
  });

  it.each([
    ['start' as const, 'starting...'],
    ['stop' as const, 'stopping...'],
    ['restart' as const, 'restarting...'],
    ['apply' as const, 'applying...'],
    ['install' as const, 'installer running...'],
  ])('names the %s operation', (busy, label) => {
    expect(getServiceStatusDisplay({ running: true, busy })).toEqual({
      label,
      tone: 'progress',
    });
  });
});
