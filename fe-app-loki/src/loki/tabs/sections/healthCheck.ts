// The health check options a URLTest and a Fallback group share.

import {
  singBoxDurationSeconds,
  validateRequiredSingBoxDuration,
} from '../../../validators/validateSingBoxDuration';
import { currentOptionValue } from './subscriptions/model';

// Status codes 100-599 and ordered ranges of them, at most 28 in all, as the backend takes them.
export function validateExpectedStatus(value: unknown) {
  const normalized = `${value || ''}`.trim();
  if (!normalized || normalized === '*') {
    return true;
  }

  const parts = normalized.replaceAll(',', '/').split('/');
  const valid =
    parts.length <= 28 &&
    parts.every((part) => {
      if (!part.trim()) {
        return true;
      }
      const codes = part
        .split('-')
        .map((bound) => bound.trim().replace(/[[\] ]/g, ''));
      return (
        codes.length <= 2 &&
        codes.every(
          (code) =>
            /^[0-9]+$/.test(code) && Number(code) >= 100 && Number(code) <= 599,
        ) &&
        (codes.length === 1 || Number(codes[0]) <= Number(codes[1]))
      );
    });
  return valid ? true : _('Format: *, 204, 200-299');
}

export function addExpectedStatusOption(itemSection: CBISection) {
  const o = itemSection.option(
    form.Value,
    'expected_status',
    _('Expected status'),
    _(
      'HTTP status codes of a successful check. * is any response, or values and ranges: 204/200-299',
    ),
  );
  o.default = '*';
  o.validate = function (_itemId: string, value: unknown) {
    return validateExpectedStatus(value);
  };
}

// Only the idle timeout differs: a URLTest can wait longer than a Fallback. A timeout shorter
// than the check interval would stop the checks before the next one, which the backend refuses.
export function addGroupHealthCheckTailOptions(
  itemSection: CBISection,
  idleTimeoutDefault: string,
  intervalOption: string,
) {
  let o = itemSection.option(
    form.Value,
    'idle_timeout',
    _('Idle timeout'),
    _('How long until health checks stop when the group is unused'),
  );
  o.default = idleTimeoutDefault;
  o.validate = function (itemId: string, value: unknown) {
    const duration = validateRequiredSingBoxDuration(value);
    if (duration !== true) {
      return duration;
    }
    const interval = singBoxDurationSeconds(
      currentOptionValue(this, itemId, intervalOption),
    );
    return interval != null && interval > singBoxDurationSeconds(value)!
      ? _('Shorter than the check interval')
      : true;
  };

  o = itemSection.option(
    form.Flag,
    'interrupt_exist_connections',
    _('Interrupt connections'),
    _('Drop every active connection when the selected server changes'),
  );
  o.default = '0';
  o.rmempty = false;
}
