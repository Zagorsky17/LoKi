// LuCI hands a list option back as a bare string for one value and an array for several; these
// helpers take both and answer in one shape.

import { LOKI_UCI_PACKAGE } from '../../constants';
import { normalizeDynamicListItems, normalizeOptionValues } from './listValues';

export function valuesToText(values: unknown): string {
  if (!values) {
    return '';
  }

  if (Array.isArray(values)) {
    return values.filter(Boolean).join('\n');
  }

  return values ? `${values}` : '';
}

export function getUciSectionName(section: UciSectionObject | null): string {
  return section && section['.name'] ? section['.name'] : '';
}

export function getUciSectionLabel(section: UciSectionObject | null): string {
  return (section && (section.label as string)) || getUciSectionName(section);
}

export function plainObject(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

export function getConfigListValues(section_id: string, key: string): string[] {
  return normalizeOptionValues(uci.get(LOKI_UCI_PACKAGE, section_id, key));
}

export function stringArraysEqual(left: unknown, right: unknown): boolean {
  const first = normalizeDynamicListItems(left);
  const second = normalizeDynamicListItems(right);

  return (
    first.length === second.length &&
    first.every((value, index) => value === second[index])
  );
}

// An unchanged list is not written: LuCI counts any set() as a change.
export function writeListOption(
  section_id: string,
  key: string,
  values: unknown,
): void {
  const normalized = normalizeOptionValues(values);

  if (stringArraysEqual(getConfigListValues(section_id, key), normalized)) {
    return;
  }

  if (normalized.length) {
    uci.set(LOKI_UCI_PACKAGE, section_id, key, normalized);
  } else {
    uci.unset(LOKI_UCI_PACKAGE, section_id, key);
  }
}
