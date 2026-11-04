function compactMonitoringText(value: string): string {
  return value
    .replace(/\u2026/g, '')
    .trim()
    .replace(/\s+/g, '');
}

// A selection starting where the value does and covering about what fits in the cell copies the
// whole value, which an ellipsis cuts off; anything less copies the selection.
export function shouldCopyFullMonitoringValue(
  element: HTMLElement,
  selectedText: string,
  fullText: string,
): boolean {
  const selected = selectedText.replace(/\u2026/g, '').trim();
  const full = fullText.trim();

  if (!selected || !full) {
    return false;
  }

  if (selected === full) {
    return true;
  }

  if (element.scrollWidth <= element.clientWidth + 1) {
    return false;
  }

  const compactSelected = compactMonitoringText(selectedText);
  const compactFull = compactMonitoringText(fullText);

  if (!compactFull.startsWith(compactSelected)) {
    return false;
  }

  const visibleChars = Math.floor(
    (element.clientWidth / Math.max(element.scrollWidth, 1)) *
      compactFull.length,
  );

  return compactSelected.length >= Math.max(4, visibleChars - 2);
}
