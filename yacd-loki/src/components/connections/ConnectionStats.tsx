import cx from 'clsx';
import * as React from 'react';
import { useTranslation } from 'react-i18next';

import prettyBytes from '~/misc/pretty-bytes';

import s from './ConnectionStats.module.scss';

/** prettyBytes 的输出拆成数值和单位，便于两者用不同字号 */
function splitBytes(n: number): [string, string] {
  const [value, unit] = prettyBytes(n).split(' ');
  return [value, unit];
}

type Props = {
  activeCount: number;
  downloadSpeed: number;
  uploadSpeed: number;
  downloadTotal: number;
  uploadTotal: number;
};

function Stat({
  label,
  value,
  unit,
  hint,
  tone,
}: {
  label: string;
  value: string;
  unit: string;
  hint?: string;
  tone?: 'download' | 'upload';
}) {
  return (
    <div className={s.card}>
      <span className={s.label}>{label}</span>
      <div className={s.valueRow}>
        <span
          className={cx(s.value, {
            [s.download]: tone === 'download',
            [s.upload]: tone === 'upload',
          })}
        >
          {value}
        </span>
        <span className={s.unit}>{unit}</span>
      </div>
      <span className={s.hint}>{hint ?? ''}</span>
    </div>
  );
}

export function ConnectionStats({
  activeCount,
  downloadSpeed,
  uploadSpeed,
  downloadTotal,
  uploadTotal,
}: Props) {
  const { t } = useTranslation();

  const [dlValue, dlUnit] = splitBytes(downloadSpeed);
  const [ulValue, ulUnit] = splitBytes(uploadSpeed);
  const [totalValue, totalUnit] = splitBytes(downloadTotal + uploadTotal);

  return (
    <div className={s.grid}>
      <Stat label={t('Active Connections')} value={String(activeCount)} unit={t('conn_unit')} />
      <Stat label={t('c_dl_speed')} value={dlValue} unit={`${dlUnit}/s`} tone="download" />
      <Stat label={t('c_ul_speed')} value={ulValue} unit={`${ulUnit}/s`} tone="upload" />
      <Stat
        label={t('total_traffic')}
        value={totalValue}
        unit={totalUnit}
        hint={`↓ ${prettyBytes(downloadTotal)} · ↑ ${prettyBytes(uploadTotal)}`}
      />
    </div>
  );
}
