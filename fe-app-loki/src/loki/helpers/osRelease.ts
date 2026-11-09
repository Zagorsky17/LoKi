// OPENWRT_RELEASE ends in the build id ("ImmortalWrt 24.10.5 r33805-7c4e882aaf6f"); the report
// keeps it, the panel row drops it.
const BUILD_ID = /\s+r\d+(?:[-+][0-9a-z]+)*$/i;

export function formatOsRelease(value: string) {
  const release = `${value ?? ''}`.trim();
  const trimmed = release.replace(BUILD_ID, '').trim();

  return trimmed || release;
}
