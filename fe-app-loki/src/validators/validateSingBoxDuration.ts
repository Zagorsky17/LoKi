import { message } from './messages';

// Number-and-unit pairs with a non-zero amount, as sing-box parses them: "0s" would mean no timeout.
export function isSingBoxDuration(value: string) {
  return /^(?=.*[1-9])([0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h|d))+$/.test(value);
}

const UNIT_SECONDS: Record<string, number> = {
  ns: 1e-9,
  us: 1e-6,
  ms: 1e-3,
  s: 1,
  m: 60,
  h: 3600,
  d: 86400,
};

// The seconds a duration stands for, or null when it is none.
export function singBoxDurationSeconds(value: unknown) {
  const text = `${value ?? ''}`.trim();
  if (!isSingBoxDuration(text)) {
    return null;
  }
  return [...text.matchAll(/([0-9]+(?:\.[0-9]+)?)(ns|us|ms|s|m|h|d)/g)].reduce(
    (total, [, amount, unit]) => total + Number(amount) * UNIT_SECONDS[unit],
    0,
  );
}

export function validateOptionalSingBoxDuration(value: unknown) {
  const normalized = value ? `${value}`.trim() : '';

  return !normalized || isSingBoxDuration(normalized)
    ? true
    : message.duration();
}

export function validateRequiredSingBoxDuration(value: unknown) {
  const normalized = value ? `${value}`.trim() : '';

  return normalized
    ? validateOptionalSingBoxDuration(normalized)
    : message.required();
}
