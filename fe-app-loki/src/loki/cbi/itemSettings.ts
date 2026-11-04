import { LOKI_UCI_PACKAGE } from '../../constants';

const sharedChildPendingSettings = new Map<
  string,
  Record<string, ChildSettings>
>();

export function readItemSettingsMap(
  section_id: string,
  settingsKey: string,
): Record<string, ChildSettings> {
  const raw = uci.get(LOKI_UCI_PACKAGE, section_id, settingsKey);

  if (!raw) {
    return {};
  }

  try {
    const parsed = JSON.parse(`${raw}`);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed
      : {};
  } catch (_error) {
    return {};
  }
}

export function itemSettingsFlag(
  settings: ChildSettings | null | undefined,
  key: string,
  defaultValue: boolean,
): boolean {
  const value = settings ? settings[key] : null;

  if (value === undefined || value === null || value === '') {
    return Boolean(defaultValue);
  }

  return value === true || `${value}` === '1';
}

export function settingValueEquals(left: unknown, right: unknown): boolean {
  const normalize = (value: unknown) => {
    if (Array.isArray(value)) {
      return JSON.stringify(value.map((item) => `${item || ''}`));
    }

    return value === undefined || value === null ? '' : `${value}`;
  };

  return normalize(left) === normalize(right);
}

export function readChildSettings(
  itemId: string,
  keys: string[],
  defaults: ChildSettings,
): ChildSettings {
  const result = Object.assign({}, defaults || {});

  keys.forEach((key: string) => {
    const value = uci.get(LOKI_UCI_PACKAGE, itemId, key);
    if (value !== null && value !== undefined) {
      result[key] = Array.isArray(value) ? value.slice() : value;
    }
  });

  return result;
}

export function changedSettings(
  base: ChildSettings,
  next: ChildSettings,
  keys: string[],
): ChildSettings {
  const result: ChildSettings = {};

  keys.forEach((key: string) => {
    if (!settingValueEquals(base ? base[key] : null, next ? next[key] : null)) {
      result[key] = next ? next[key] : null;
    }
  });

  return result;
}

export function hasChangedSettings(settings: ChildSettings): boolean {
  return Object.keys(settings || {}).length > 0;
}

export function childPendingSettingsStore(
  option: CBIOption,
  section_id: string,
): Record<string, ChildSettings> {
  if (option.sharedPendingSettingsKey) {
    const key = `${option.sharedPendingSettingsKey}:${section_id}`;
    if (!sharedChildPendingSettings.has(key)) {
      sharedChildPendingSettings.set(key, {});
    }
    return sharedChildPendingSettings.get(key) as Record<string, ChildSettings>;
  }

  if (!option.pendingChildSettings) {
    option.pendingChildSettings = {};
  }

  if (!option.pendingChildSettings[section_id]) {
    option.pendingChildSettings[section_id] = {};
  }

  return option.pendingChildSettings[section_id];
}

export function pendingChildSettings(
  option: CBIOption,
  section_id: string,
  value: unknown,
  defaults: ChildSettings,
): ChildSettings {
  const itemValue = `${value || ''}`.trim();
  const store = childPendingSettingsStore(option, section_id);

  // What the list already staged wins; the defaults fill in the rest.
  store[itemValue] = Object.assign({}, defaults || {}, store[itemValue]);

  return store[itemValue];
}

// Shared drafts live as long as the page, so a closing dialog clears what it staged.
export function clearSharedChildPendingSettings() {
  sharedChildPendingSettings.clear();
}

export function clearChildPendingSettings(
  option: CBIOption,
  section_id: string,
) {
  if (option.sharedPendingSettingsKey) {
    sharedChildPendingSettings.delete(
      `${option.sharedPendingSettingsKey}:${section_id}`,
    );
    return;
  }

  if (option.pendingChildSettings) {
    delete option.pendingChildSettings[section_id];
  }
}
