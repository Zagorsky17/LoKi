// A widget hands back one typed entry that may hold spaces (a display name), so
// normalizeDynamicListItems keeps it whole; uci hands a single-value list as a bare string,
// space-separated if written before the option was a list, so normalizeOptionValues splits it.

export function normalizeDynamicListItems(value: unknown): string[] {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .map((item) => `${item || ''}`.trim())
      .filter((item) => item.length);
  }

  const normalized = `${value}`.trim();
  return normalized.length ? [normalized] : [];
}

export function normalizeOptionValues(value: unknown): string[] {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .filter(Boolean)
      .map((item) => `${item}`.trim())
      .filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

export function uniqueDynamicListItems(value: unknown): string[] {
  const seen = new Set<string>();
  const result: string[] = [];

  normalizeDynamicListItems(value).forEach((item) => {
    if (!seen.has(item)) {
      seen.add(item);
      result.push(item);
    }
  });

  return result;
}
