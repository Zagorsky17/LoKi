const DAY_MS = 24 * 60 * 60 * 1000;

const twoDigits = (value: number) => String(value).padStart(2, '0');

const startOfDay = (date: Date) =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();

// When a run began or ended, by the router's clock in the viewer's time zone: the time alone
// today, yesterday's as such, and the date before that.
export function formatRunTime(seconds: number, now: Date = new Date()): string {
  const at = new Date(seconds * 1000);
  const time = `${twoDigits(at.getHours())}:${twoDigits(at.getMinutes())}`;
  const days = Math.round((startOfDay(now) - startOfDay(at)) / DAY_MS);
  if (days === 0) {
    return time;
  }
  if (days === 1) {
    return _('yesterday %s').format(time);
  }
  return `${twoDigits(at.getDate())}.${twoDigits(at.getMonth() + 1)} ${time}`;
}
