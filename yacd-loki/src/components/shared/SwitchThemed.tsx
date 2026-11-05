import * as Switch from '@radix-ui/react-switch';
import cx from 'clsx';
import * as React from 'react';

import s from './SwitchThemed.module.scss';

type Props = {
  checked?: boolean;
  onChange?: (checked: boolean) => void;
  name?: string;
  disabled?: boolean;
  size?: 'default' | 'mini';
};

export default function SwitchThemed({
  checked = false,
  onChange,
  name,
  disabled,
  size = 'default',
}: Props) {
  return (
    <Switch.Root
      className={cx(s.root, { [s.mini]: size === 'mini' })}
      checked={checked}
      onCheckedChange={onChange}
      name={name}
      disabled={disabled}
    >
      <Switch.Thumb className={s.thumb} />
    </Switch.Root>
  );
}
