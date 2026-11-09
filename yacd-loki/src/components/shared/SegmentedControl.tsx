import cx from 'clsx';
import * as React from 'react';

import s from './SegmentedControl.module.scss';

export type SegmentedOption<T extends string | number> = {
  value: T;
  label: React.ReactNode;
  title?: string;
};

type Props<T extends string | number> = {
  options: SegmentedOption<T>[];
  value: T;
  onChange: (value: T) => void;
  label?: string;
  className?: string;
};

/** 分段选择器：一条轨道内若干选项，选中项以白色药丸高亮 */
export function SegmentedControl<T extends string | number>({
  options,
  value,
  onChange,
  label,
  className,
}: Props<T>) {
  return (
    <div className={cx(s.track, className)} role="radiogroup" aria-label={label}>
      {options.map((o) => {
        const selected = o.value === value;
        return (
          <button
            key={o.value}
            type="button"
            role="radio"
            aria-checked={selected}
            title={o.title}
            className={cx(s.segment, { [s.selected]: selected })}
            onClick={() => onChange(o.value)}
          >
            {o.label}
          </button>
        );
      })}
    </div>
  );
}
