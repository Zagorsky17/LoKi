import { LOKI_UCI_PACKAGE } from '../../constants';
import { message } from '../../validators/messages';
import { getUciSectionLabel, getUciSectionName } from './uci';

// A dropdown hands back only its own entries, so a stored section it lacks (deleted or switched
// off) would be replaced on save by the first entry. The stored name is kept as an entry, and
// validateSectionChoice marks it.
export function keepUnavailableSectionChoice(
  option: CBIOption,
  storedValue: unknown,
) {
  const value = `${storedValue || ''}`.trim();

  if (!value || (option.keylist || []).includes(value)) {
    option.unavailableChoice = '';
    return;
  }

  const target = (uci.sections(LOKI_UCI_PACKAGE, 'section') || []).find(
    (section) => getUciSectionName(section) === value,
  );

  option.unavailableChoice = value;
  option.value(
    value,
    _('%s (section is unavailable)').format(
      target ? getUciSectionLabel(target) : value,
    ),
  );
}

export function validateSectionChoice(
  option: CBIOption,
  value: unknown,
  ownSection?: string,
) {
  const section = `${value || ''}`.trim();
  if (!section) {
    return message.required();
  }
  if (section === ownSection) {
    return message.sectionSelf();
  }
  return option.unavailableChoice && section === option.unavailableChoice
    ? message.sectionUnavailable()
    : true;
}

export function refreshOptionChoices(
  option: CBIOption,
  choices: ChoiceEntry[] | null | undefined,
) {
  delete option.keylist;
  delete option.vallist;

  (choices || []).forEach((choice) => {
    if (typeof choice === 'object') {
      option.value(choice.value, choice.label);
    } else {
      option.value(choice);
    }
  });
}
