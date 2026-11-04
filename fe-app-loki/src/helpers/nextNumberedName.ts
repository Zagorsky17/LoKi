// One past the highest number taken, not the count, which would offer a name still in use.
export function nextNumberedName(
  prefix: string,
  taken: string[],
  separator: string = ' #',
) {
  const marker = `${prefix}${separator}`;
  const highest = Math.max(
    0,
    ...taken.map((name) => {
      const label = `${name}`.trim();
      const digits = label.slice(marker.length);
      return label.startsWith(marker) && /^\d+$/.test(digits)
        ? Number(digits)
        : 0;
    }),
  );
  return `${marker}${highest + 1}`;
}
