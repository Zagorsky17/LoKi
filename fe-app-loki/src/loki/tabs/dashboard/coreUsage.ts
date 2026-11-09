import { callUbus } from '../../../helpers/callUbus';
import {
  LOKI_CALL_TIMEOUT_MS,
  LOKI_SERVICE_OBJECT,
} from '../../services/lokiWaitTransport';
import type { Loki } from '../../types';

// procfs counts processor time and process starts in ticks of USER_HZ, which
// Linux fixes at 100 for userspace whatever the kernel's own tick rate.
const TICKS_PER_SECOND = 100;

export type CoreUsageReading = Extract<Loki.CoreUsage, { running: true }>;

// Readings of two different core processes, or not apart in time, say nothing about the load.
export function cpuShare(
  previous: CoreUsageReading | null,
  next: CoreUsageReading,
): number | null {
  if (!previous || previous.started !== next.started) {
    return null;
  }

  const seconds = (next.clock_ms - previous.clock_ms) / 1000;
  const used = (next.cpu_ticks - previous.cpu_ticks) / TICKS_PER_SECOND;
  if (seconds <= 0 || used < 0) {
    return null;
  }

  return (used / seconds / Math.max(1, next.cpus)) * 100;
}

export function coreAgeSeconds(reading: CoreUsageReading) {
  return Math.max(
    0,
    reading.clock_ms / 1000 - reading.started / TICKS_PER_SECOND,
  );
}

export function formatCpuShare(percent: number) {
  return `${percent < 10 ? percent.toFixed(1) : Math.round(percent)}%`;
}

// The poll is the retry, so a missing service fails the reading at once.
export function readCoreUsage() {
  return callUbus<Loki.CoreUsage>({
    object: LOKI_SERVICE_OBJECT,
    method: 'usage',
    timeoutMs: LOKI_CALL_TIMEOUT_MS,
    retryUnavailable: false,
  });
}
