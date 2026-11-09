import type { PrimitiveAtom } from 'jotai';
import * as React from 'react';

import { useTextInput } from '~/hooks/useTextInput';

import s from './TextFilter.module.scss';

export function TextFilter(props: { textAtom: PrimitiveAtom<string>; placeholder?: string }) {
  const [onChange, text] = useTextInput(props.textAtom);
  return (
    <input
      className={s.input}
      type="text"
      value={text}
      onChange={onChange}
      placeholder={props.placeholder}
    />
  );
}
