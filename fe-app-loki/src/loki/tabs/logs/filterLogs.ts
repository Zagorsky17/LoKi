export function filterLogText(text: string, query: string) {
  const normalizedQuery = query.trim().toLowerCase();

  return text
    .split(/\r?\n/)
    .filter((line) => {
      if (!line) {
        return false;
      }

      return !normalizedQuery || line.toLowerCase().includes(normalizedQuery);
    })
    .join('\n');
}
