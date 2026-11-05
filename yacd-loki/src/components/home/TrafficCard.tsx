import cx from 'clsx';
import { Suspense } from 'react';
import { useTranslation } from 'react-i18next';

import { chartStyles } from '~/misc/chart';
import { CHART_WINDOW, useTraffic } from '~/modules/home/hooks';
import { splitTrafficRate } from '~/modules/home/utils';
import { ClashAPIConfig } from '~/types';

import s from './Home.module.scss';
import TrafficChart from './TrafficChart';

type Props = {
  apiConfig: ClashAPIConfig;
  selectedChartStyleIndex: number;
};

function Legend({ label, color, rate }: { label: string; color: string; rate: number }) {
  const { value, unit } = splitTrafficRate(rate);
  return (
    <div className={s.legendItem}>
      <span className={s.legendLabel}>
        <span className={s.dot} style={{ backgroundColor: color }} />
        {label}
      </span>
      <span className={s.legendValue}>
        <span>{value}</span>
        <em className={s.unit}>{unit}</em>
      </span>
    </div>
  );
}

export default function TrafficCard({ apiConfig, selectedChartStyleIndex }: Props) {
  const { t } = useTranslation();
  const traffic = useTraffic(apiConfig);
  const style = chartStyles[selectedChartStyleIndex] || chartStyles[0];

  const downLabel = t('Download');
  const upLabel = t('Upload');

  return (
    <section className={cx(s.card, s.trafficCard)}>
      <div className={s.cardHead}>
        <div>
          <h2 className={s.cardTitle}>{t('realtime_traffic')}</h2>
          <p className={s.cardSubtitle}>{t('last_n_seconds', { seconds: CHART_WINDOW })}</p>
        </div>
        <div className={s.legend}>
          <Legend
            label={downLabel}
            color={style.down.borderColor}
            rate={traffic.down[traffic.down.length - 1] || 0}
          />
          <Legend
            label={upLabel}
            color={style.up.borderColor}
            rate={traffic.up[traffic.up.length - 1] || 0}
          />
        </div>
      </div>
      <div className={s.chart}>
        <Suspense fallback={null}>
          <TrafficChart
            traffic={traffic}
            styleIndex={selectedChartStyleIndex}
            downLabel={downLabel}
            upLabel={upLabel}
          />
        </Suspense>
      </div>
    </section>
  );
}
