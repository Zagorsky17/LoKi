// In the order traffic depends on them.
export enum DIAGNOSTICS_CHECKS {
  SERVICE = 'SERVICE',
  DNS = 'DNS',
  TRAFFIC = 'TRAFFIC',
  SECTIONS = 'SECTIONS',
}

export const DIAGNOSTICS_CHECKS_ORDER = [
  DIAGNOSTICS_CHECKS.SERVICE,
  DIAGNOSTICS_CHECKS.DNS,
  DIAGNOSTICS_CHECKS.TRAFFIC,
  DIAGNOSTICS_CHECKS.SECTIONS,
];

export function diagnosticsCheckTitle(code: DIAGNOSTICS_CHECKS) {
  switch (code) {
    case DIAGNOSTICS_CHECKS.SERVICE:
      return _('Service');
    case DIAGNOSTICS_CHECKS.DNS:
      return 'DNS';
    case DIAGNOSTICS_CHECKS.TRAFFIC:
      return _('Traffic');
    case DIAGNOSTICS_CHECKS.SECTIONS:
      return _('Sections');
  }
}
