import { describe, expect, it } from 'vitest';

import {
  saveLogNotificationHandoff,
  takeLogNotificationHandoff,
} from '../logNotificationHandoff.service';

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

const LINE = 'Tue Sep 29 00:46:49 2026 user.notice loki: [error] refused';

describe('the log notification handoff', () => {
  it('hands the open alerts and the cursor to the page LuCI loads next, once', () => {
    const storage = new MemoryStorage();
    saveLogNotificationHandoff({ cursor: 42, lines: [LINE] }, storage, 1000);

    expect(takeLogNotificationHandoff(storage, 3000)).toEqual({
      cursor: 42,
      lines: [LINE],
    });
    expect(takeLogNotificationHandoff(storage, 3000)).toBeNull();
  });

  it('drops what a page left long before, as history', () => {
    const storage = new MemoryStorage();
    saveLogNotificationHandoff({ cursor: 42, lines: [LINE] }, storage, 1000);

    expect(takeLogNotificationHandoff(storage, 1000 + 60000)).toBeNull();
    expect(storage.length).toBe(0);
  });

  it('ignores what it cannot read', () => {
    const storage = new MemoryStorage();
    storage.setItem('loki:log-notification-handoff:v1', '{"at":1000');
    expect(takeLogNotificationHandoff(storage, 1000)).toBeNull();

    storage.setItem(
      'loki:log-notification-handoff:v1',
      JSON.stringify({ at: 1000, cursor: '42', lines: [LINE] }),
    );
    expect(takeLogNotificationHandoff(storage, 1000)).toBeNull();
    expect(takeLogNotificationHandoff(null, 1000)).toBeNull();
  });
});
