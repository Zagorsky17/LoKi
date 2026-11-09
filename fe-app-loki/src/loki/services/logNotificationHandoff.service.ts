import { getSessionStorage } from './browserStorage.service';

// LuCI reloads the page right after an apply, so the leaving page hands the next one its open
// alerts and its log cursor.
const HANDOFF_STORAGE_KEY = 'loki:log-notification-handoff:v1';

// Older than this, the handoff came from a page the user left, and its lines are history.
const HANDOFF_MAX_AGE_MS = 30000;

export type LogNotificationHandoff = { cursor: number; lines: string[] };

export function saveLogNotificationHandoff(
  handoff: LogNotificationHandoff,
  storage: Storage | null = getSessionStorage(),
  now = Date.now(),
) {
  try {
    storage?.setItem(
      HANDOFF_STORAGE_KEY,
      JSON.stringify({ at: now, cursor: handoff.cursor, lines: handoff.lines }),
    );
  } catch {
    // Without storage the next page starts reading where the log stands.
  }
}

export function dropLogNotificationHandoff(
  storage: Storage | null = getSessionStorage(),
) {
  try {
    storage?.removeItem(HANDOFF_STORAGE_KEY);
  } catch {
    // Storage is blocked, so nothing was stored.
  }
}

export function takeLogNotificationHandoff(
  storage: Storage | null = getSessionStorage(),
  now = Date.now(),
): LogNotificationHandoff | null {
  let raw: string | null = null;
  try {
    raw = storage?.getItem(HANDOFF_STORAGE_KEY) ?? null;
  } catch {
    return null;
  }
  dropLogNotificationHandoff(storage);
  if (!raw) {
    return null;
  }

  try {
    const parsed = JSON.parse(raw);
    const age = now - Number(parsed?.at);
    if (
      !(age >= 0 && age <= HANDOFF_MAX_AGE_MS) ||
      typeof parsed.cursor !== 'number' ||
      !Array.isArray(parsed.lines)
    ) {
      return null;
    }
    return {
      cursor: parsed.cursor,
      lines: parsed.lines.filter(
        (line: unknown): line is string => typeof line === 'string',
      ),
    };
  } catch {
    return null;
  }
}
