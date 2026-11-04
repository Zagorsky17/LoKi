import { message } from './messages';
import { asciiHostname, validAsciiDomain } from './validateDomain';
import { isIPv4, isIPv6 } from './validateIp';

// LuCI datatype checks in the page's words; an empty value is left to the field.

export function wholeNumberField(min: number, max = Infinity) {
  return (_sectionId: string, value: unknown) => {
    const text = `${value ?? ''}`.trim();
    const number = Number(text);
    return !text || (/^[0-9]+$/.test(text) && number >= min && number <= max)
      ? true
      : max === Infinity
        ? _('Whole number from %d').format(min)
        : message.wholeNumber(min, max);
  };
}

export function portField(_sectionId: string, value: unknown) {
  return wholeNumberField(1, 65535)(_sectionId, value) === true
    ? true
    : message.invalidPort();
}

// A port the core may pick itself, which 0 asks it to.
export function anyPortField(_sectionId: string, value: unknown) {
  return wholeNumberField(0, 65535)(_sectionId, value) === true
    ? true
    : message.invalidPort();
}

export function domainField(_sectionId: string, value: unknown) {
  const text = `${value ?? ''}`.trim();
  const ascii = asciiHostname(text.toLowerCase());
  return !text || (ascii && validAsciiDomain(ascii, false))
    ? true
    : message.invalidDomain();
}

export function hostField(_sectionId: string, value: unknown) {
  const text = `${value ?? ''}`.trim();
  return !text ||
    isIPv4(text) ||
    isIPv6(text) ||
    domainField(_sectionId, text) === true
    ? true
    : message.invalidHost();
}

export function ipv4Field(_sectionId: string, value: unknown) {
  const text = `${value ?? ''}`.trim();
  return !text || isIPv4(text) ? true : message.invalidIp();
}

export function ipv6Field(_sectionId: string, value: unknown) {
  const text = `${value ?? ''}`.trim();
  return !text || isIPv6(text) ? true : message.invalidIp();
}
