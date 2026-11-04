import { describe, expect, it } from 'vitest';

import { configureTextareaOption } from '../../loki/cbi/annotatedTextarea';
import { MAX_SAVED_KB, validateSavedSize } from '../validateSavedSize';

// JSON.stringify adds the two quotes around the text.
const fitting = 'a'.repeat(MAX_SAVED_KB * 1024 - 2);

describe('validateSavedSize', () => {
  it('takes a text that fits one save request', () => {
    expect(validateSavedSize(fitting)).toBe(true);
    expect(validateSavedSize('')).toBe(true);
  });

  it('counts the text as the request carries it: escaped and in UTF-8', () => {
    expect(validateSavedSize(`${fitting}a`)).toBe(
      'At most %d KB, this is %d KB'.format(MAX_SAVED_KB, MAX_SAVED_KB + 1),
    );
    const lines = 'example.com\n'.repeat(Math.ceil(fitting.length / 12));
    expect(validateSavedSize(lines.slice(0, fitting.length - 2048))).not.toBe(
      true,
    );
    expect(validateSavedSize('ы'.repeat(fitting.length / 2 + 1))).not.toBe(
      true,
    );
  });
});

describe('a textarea option', () => {
  function rendered(
    validate: (sectionId: string, value: string) => string | true,
  ) {
    const option = {
      renderWidget: () => null,
    } as unknown as CBIOption;
    configureTextareaOption(option);
    option.validate = validate;
    option.renderWidget('section', '0', '');
    option.renderWidget('section', '0', '');
    return option;
  }

  it('refuses a value too long to save before its own check, set after it was configured', () => {
    const seen: unknown[] = [];
    const option = rendered((_sectionId, value) => {
      seen.push(value);
      return value === 'bad' ? 'Bad value' : true;
    });

    expect(option.validate('section', `${fitting}a`)).toMatch(/^At most/);
    expect(option.validate('section', 'bad')).toBe('Bad value');
    expect(option.validate('section', 'good')).toBe(true);
    expect(seen).toEqual(['bad', 'good']);
  });
});
