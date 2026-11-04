import { describe, expect, it } from 'vitest';

import {
  getLogNotificationKey,
  getLokiLogNotification,
  isErrorLogLine,
  LogNotificationDeduper,
} from '../logNotificationDeduper.service';

class MemoryStorage implements Storage {
  private values = new Map<string, string>();

  get length() {
    return this.values.size;
  }

  clear() {
    this.values.clear();
  }

  getItem(key: string) {
    return this.values.get(key) ?? null;
  }

  key(index: number) {
    return Array.from(this.values.keys())[index] ?? null;
  }

  removeItem(key: string) {
    this.values.delete(key);
  }

  setItem(key: string, value: string) {
    this.values.set(key, value);
  }
}

describe('LogNotificationDeduper', () => {
  it('accepts only Loki errors', () => {
    expect(isErrorLogLine('loki: [info] ok')).toBe(false);
    expect(isErrorLogLine('loki: [error] failed')).toBe(true);
    expect(isErrorLogLine('loki: [warn] retrying what [error] said')).toBe(
      false,
    );
    expect(isErrorLogLine('sing-box[123]: [error] dial failed')).toBe(false);
    expect(
      isErrorLogLine(
        'daemon.err sing-box[123]: ERROR[0000] connection: dial failed',
      ),
    ).toBe(false);
    expect(getLokiLogNotification('loki: [info] ok')).toBeNull();
    expect(
      getLokiLogNotification(
        'Tue Sep 29 02:38:25 2026 user.err loki: [error] Failed to reload sing-box',
      ),
    ).toEqual({
      kind: 'error',
      line: 'Tue Sep 29 02:38:25 2026 user.err loki: [error] Failed to reload sing-box',
      message: 'Failed to reload sing-box',
    });
    expect(
      getLokiLogNotification('sing-box[123]: [error] dial failed'),
    ).toBeNull();
  });

  it('dedupes already shown log lines through session storage', () => {
    const storage = new MemoryStorage();
    const first = new LogNotificationDeduper(storage);

    expect(first.shouldNotify('loki: [error] failed')).toBe(true);
    expect(first.shouldNotify('loki: [error] failed')).toBe(false);
    expect(first.shouldNotify('loki: [error] another failure')).toBe(true);
    expect(first.shouldNotify('sing-box[123]: [error] dial failed')).toBe(
      false,
    );

    const afterReload = new LogNotificationDeduper(storage);

    expect(afterReload.shouldNotify('loki: [error] failed')).toBe(false);
    expect(afterReload.shouldNotify('loki: [error] a later failure')).toBe(
      true,
    );
  });

  it('keeps the full log line as the replay key', () => {
    expect(getLogNotificationKey('  Jun 06 loki: [error] failed  ')).toBe(
      'Jun 06 loki: [error] failed',
    );
  });

  it('remembers only the latest lines it showed', () => {
    const storage = new MemoryStorage();
    const deduper = new LogNotificationDeduper(storage);
    const line = (index: number) => `loki: [error] failure ${index}`;

    for (let index = 0; index <= 500; index++) {
      deduper.shouldNotify(line(index));
    }

    const stored = JSON.parse(
      storage.getItem('loki:shown-log-error-notifications:v1') || '[]',
    );
    expect(stored).toHaveLength(500);
    expect(stored[0]).toBe(line(1));
    expect(deduper.shouldNotify(line(500))).toBe(false);
    expect(deduper.shouldNotify(line(0))).toBe(true);
  });
});
