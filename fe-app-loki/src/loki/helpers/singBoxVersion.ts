export function formatSingBoxVersion(value: { sing_box_version?: string }) {
  const version = String(value.sing_box_version || '');

  return !version || version === 'not installed' ? _('Not installed') : version;
}
