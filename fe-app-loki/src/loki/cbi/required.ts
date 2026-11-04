// LuCI checks every field when a dialog opens, so a check refusing an empty value marks a
// required field at once. rmempty = false would make LuCI refuse it in its own words first, so
// it is left alone.

import { message } from '../../validators/messages';
import { normalizeDynamicListItems } from './listValues';

type FieldCheck = (
  this: CBIOption,
  sectionId: string,
  value: string,
) => true | string;

function isBlank(value: unknown) {
  return `${value ?? ''}`.trim() === '';
}

// The widget while the dialog is open, the stored value when it is not mounted.
export function optionListValues(option: CBIOption, sectionId: string) {
  const formValue = option.formvalue(sectionId);
  return normalizeDynamicListItems(
    formValue != null ? formValue : option.cfgvalue(sectionId),
  );
}

export function required(check?: FieldCheck): FieldCheck {
  return function (sectionId, value) {
    if (isBlank(value)) {
      return message.required();
    }
    return check ? check.call(this, sectionId, value) : true;
  };
}

// LuCI checks a list entry by entry and then the empty add field, which stands for the whole list.
export function requiredList(check?: FieldCheck): FieldCheck {
  return function (sectionId, value) {
    if (isBlank(value)) {
      return optionListValues(this, sectionId).length
        ? true
        : message.required();
    }
    return check ? check.call(this, sectionId, value) : true;
  };
}
