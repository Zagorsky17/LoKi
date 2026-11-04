import { describe, expect, it } from 'vitest';
import { coreAgeSeconds, cpuShare, formatCpuShare } from '../coreUsage';

function reading(started: number, clockMs: number, cpuTicks: number) {
  return {
    running: true as const,
    started,
    cpu_ticks: cpuTicks,
    memory_kb: 25152,
    cpus: 2,
    clock_ms: clockMs,
  };
}

describe('the core load', () => {
  it('is the processor time used between two readings, as a share of every core', () => {
    expect(cpuShare(reading(100, 10_000, 500), reading(100, 12_000, 600))).toBe(
      25,
    );
  });

  it('is unknown across a core restart and between readings not apart in time', () => {
    expect(cpuShare(null, reading(100, 12_000, 600))).toBeNull();
    expect(
      cpuShare(reading(100, 10_000, 500), reading(200, 12_000, 30)),
    ).toBeNull();
    expect(
      cpuShare(reading(100, 12_000, 500), reading(100, 12_000, 600)),
    ).toBeNull();
  });

  it('keeps a decimal while it is small', () => {
    expect([0.43, 9.94, 25.4].map(formatCpuShare)).toEqual([
      '0.4%',
      '9.9%',
      '25%',
    ]);
  });
});

it('the core age counts from its start on the clock of the reading', () => {
  expect(coreAgeSeconds(reading(190694980, 1_907_690_950, 281))).toBeCloseTo(
    741.15,
    2,
  );
});
