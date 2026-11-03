// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
import { normalizeCompiledVersion } from '../../helpers/normalizeCompiledVersion';

// The build writes the version into the bundle; a development build has none. LuCI rebuilds the
// heading from the map title on every save and reset, and moves these same nodes into it.
// Themes draw h2 small as the muted part of a heading.
export function pageTitle(compiledVersion: string, status: HTMLElement) {
  const version = normalizeCompiledVersion(compiledVersion);
  if (version === 'dev') {
    return ['LoKi ', status];
  }

  const small = document.createElement('small');
  small.textContent = version;
  return ['LoKi ', small, ' ', status];
}
