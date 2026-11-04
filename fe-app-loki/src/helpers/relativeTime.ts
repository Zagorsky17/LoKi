// LuCI sets the document language to the one the page is shown in.
export function pageLanguage() {
  return document.documentElement.lang || undefined;
}

const TIME_UNITS: Array<[Intl.RelativeTimeFormatUnit, number]> = [
  ['year', 31536000],
  ['month', 2592000],
  ['day', 86400],
  ['hour', 3600],
  ['minute', 60],
];

export function relativeTime(
  seconds: number,
  style: Intl.RelativeTimeFormatStyle = 'long',
) {
  const difference = seconds - Date.now() / 1000;
  const format = new Intl.RelativeTimeFormat(pageLanguage(), {
    numeric: 'auto',
    style,
  });
  for (const [unit, size] of TIME_UNITS) {
    if (Math.abs(difference) >= size) {
      return format.format(Math.round(difference / size), unit);
    }
  }
  return format.format(0, 'minute');
}
