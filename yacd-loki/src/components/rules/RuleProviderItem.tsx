import { formatDistance } from 'date-fns';
import * as React from 'react';
import { useTranslation } from 'react-i18next';

import type { RuleProvider } from '~/api/rule-provider';
import { Activity, Database } from '~/components/shared/FeatherIcons';
import { RotateIcon } from '~/components/shared/RotateIcon';
import { useUpdateRuleProviderItem } from '~/modules/rules/hooks';
import { ClashAPIConfig } from '~/types';

import s from './RuleProviderItem.module.scss';

type Props = RuleProvider & { apiConfig: ClashAPIConfig };

function RuleProviderItemInner({
  idx,
  name,
  vehicleType,
  behavior,
  updatedAt,
  ruleCount,
  apiConfig,
}: Props) {
  const { t } = useTranslation();
  const [refresh, isRefreshing] = useUpdateRuleProviderItem(name, apiConfig);
  const timeAgo = formatDistance(new Date(updatedAt), new Date());

  return (
    <div className={s.item}>
      <div className={s.index}>{idx}</div>

      <div className={s.main}>
        <div className={s.nameRow}>
          <span className={s.name}>{name}</span>
          <span className={s.badge}>
            <Database size={11} />
            {vehicleType}
          </span>
          <span className={s.badge}>
            <Activity size={11} />
            {behavior}
          </span>
        </div>
        <div className={s.infoRow}>
          <span>{t('rule_entry_count', { count: ruleCount })}</span>
          <span className={s.dot}>•</span>
          <span>{t('updated_ago', { time: timeAgo })}</span>
        </div>
      </div>

      <button
        type="button"
        className={s.refreshBtn}
        onClick={refresh}
        disabled={isRefreshing}
        aria-label={t('update_rule_provider')}
        title={t('update_rule_provider')}
      >
        <RotateIcon isRotating={isRefreshing} />
      </button>
    </div>
  );
}

export const RuleProviderItem = React.memo(RuleProviderItemInner);
