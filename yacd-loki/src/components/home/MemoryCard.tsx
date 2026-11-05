import { Suspense } from 'react';
import { useTranslation } from 'react-i18next';

import prettyBytes from '~/misc/pretty-bytes';
import { CHART_WINDOW, useMemory, useRulesCount } from '~/modules/home/hooks';
import { formatCount, latestOf, peakOf, splitBytes } from '~/modules/home/utils';
import { ClashAPIConfig } from '~/types';

import s from './Home.module.scss';
import MemoryChart from './MemoryChart';

type Props = {
  apiConfig: ClashAPIConfig;
  selectedChartStyleIndex: number;
};

export default function MemoryCard({ apiConfig, selectedChartStyleIndex }: Props) {
  const { t } = useTranslation();
  const memory = useMemory(apiConfig);
  const rulesCount = useRulesCount(apiConfig);

  const { value, unit } = splitBytes(latestOf(memory.inuse));
  const peak = peakOf(memory.inuse, CHART_WINDOW);

  return (
    <section className={s.card}>
      <h2 className={s.cardTitle}>{t('Memory Usage')}</h2>
      <p className={s.cardSubtitle}>{t('current_process_memory')}</p>
      <div className={s.value}>
        <span>{value}</span>
        <em className={s.unit}>{unit}</em>
      </div>
      <div className={s.memoryChart}>
        <Suspense fallback={null}>
          <MemoryChart memory={memory} styleIndex={selectedChartStyleIndex} />
        </Suspense>
      </div>
      <div className={s.metaRows}>
        <div className={s.metaRow}>
          <span>{t('memory_peak')}</span>
          <span className={s.metaValue}>{prettyBytes(peak)}</span>
        </div>
        <div className={s.metaRow}>
          <span>{t('rule_count')}</span>
          <span className={s.metaValue}>{formatCount(rulesCount)}</span>
        </div>
      </div>
    </section>
  );
}
