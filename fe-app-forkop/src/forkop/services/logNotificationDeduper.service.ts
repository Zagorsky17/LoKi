// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
import { getSessionStorage } from './browserStorage.service';
const LOG_NOTIFICATION_STORAGE_KEY = 'forkop:shown-log-error-notifications:v1';
const MAX_STORED_LOG_NOTIFICATIONS = 500;
// A Forkop error as logread prints it: the date, the facility, the tag and the
// level before the message the alert shows.
const FORKOP_ERROR_LINE_PATTERN = /\bforkop(?:\[\d+\])?:\s+\[error\]\s+(.*)$/i;
const FORKOP_INFO_LINE_PATTERN = /\bforkop(?:\[\d+\])?:\s+\[info\]\s+(.*)$/i;

// The first line of each Forkop action: a start, a stop, an apply and a reapply.
// A restart is a stop and a start.
export const FORKOP_ACTION_OPENINGS = [
  'Starting LoKi',
  'Stopping LoKi',
  'Applying configuration',
  'Reapplying configuration',
];

export type ForkopLogNotification = {
  kind: 'error';
  line: string;
  message: string;
};

function readStoredKeys(storage: Storage | null): string[] {
  if (!storage) {
    return [];
  }

  try {
    const parsed = JSON.parse(
      storage.getItem(LOG_NOTIFICATION_STORAGE_KEY) || '[]',
    );

    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === 'string')
      : [];
  } catch {
    return [];
  }
}

function writeStoredKeys(storage: Storage | null, keys: string[]) {
  if (!storage) {
    return;
  }

  try {
    storage.setItem(LOG_NOTIFICATION_STORAGE_KEY, JSON.stringify(keys));
  } catch {
    // Notifications are still deduped in-memory when sessionStorage is blocked.
  }
}

export function isErrorLogLine(line: string) {
  return FORKOP_ERROR_LINE_PATTERN.test(line);
}

export function getForkopLogNotification(
  line: string,
): ForkopLogNotification | null {
  const error = line.match(FORKOP_ERROR_LINE_PATTERN);
  return error ? { kind: 'error', line, message: error[1].trim() } : null;
}

export function opensForkopAction(line: string) {
  const info = line.match(FORKOP_INFO_LINE_PATTERN);
  return (
    !!info &&
    FORKOP_ACTION_OPENINGS.some((opening) => info[1].startsWith(opening))
  );
}

export function getLogNotificationKey(line: string) {
  return line.trim();
}

export class LogNotificationDeduper {
  private readonly storage: Storage | null;
  private readonly seenKeys: Set<string>;

  constructor(storage: Storage | null = getSessionStorage()) {
    this.storage = storage;
    this.seenKeys = new Set(
      readStoredKeys(storage).slice(-MAX_STORED_LOG_NOTIFICATIONS),
    );
  }

  shouldNotify(line: string) {
    if (!getForkopLogNotification(line)) {
      return false;
    }

    const key = getLogNotificationKey(line);

    if (!key || this.seenKeys.has(key)) {
      return false;
    }

    this.seenKeys.add(key);
    for (const oldest of this.seenKeys) {
      if (this.seenKeys.size <= MAX_STORED_LOG_NOTIFICATIONS) break;
      this.seenKeys.delete(oldest);
    }
    writeStoredKeys(this.storage, Array.from(this.seenKeys));
    return true;
  }
}
