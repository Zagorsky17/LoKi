// Two units at most: "3 d 4 h", "2 h 15 min", "40 s".
export function formatDuration(seconds: number) {
  const value = Math.max(0, Math.floor(seconds));
  const days = Math.floor(value / 86400);
  const hours = Math.floor((value % 86400) / 3600);
  const minutes = Math.floor((value % 3600) / 60);

  if (days > 0) {
    return hours > 0
      ? `${_('%d d').format(days)} ${_('%d h').format(hours)}`
      : _('%d d').format(days);
  }
  if (hours > 0) {
    return minutes > 0
      ? `${_('%d h').format(hours)} ${_('%d min').format(minutes)}`
      : _('%d h').format(hours);
  }
  return minutes > 0 ? _('%d min').format(minutes) : _('%d s').format(value);
}
