import cx from 'clsx';
import { formatDistanceToNow } from 'date-fns';
import * as React from 'react';
import { useTranslation } from 'react-i18next';

import type { RuleExtra } from '~/api/rules';
import {
  Activity,
  FileText,
  Globe,
  Hash,
  Link,
  Shield,
  Zap,
} from '~/components/shared/FeatherIcons';
import type { RuleProviderIndex } from '~/modules/rules/utils';

import s from './Rule.module.scss';

const proxyColor: Record<string, string> = {
  DIRECT: '#f5bc41',
  REJECT: '#cb3166',
};

function getIconFor(type: string) {
  switch (type) {
    case 'Domain':
    case 'DomainSuffix':
    case 'DomainKeyword':
      return <Link size={12} />;
    case 'IPCIDR':
    case 'IPCIDR6':
      return <Hash size={12} />;
    case 'GeoSite':
    case 'GeoIP':
      return <Globe size={12} />;
    case 'REJECT':
      return <Shield size={12} />;
    case 'DIRECT':
      return <Zap size={12} />;
    default:
      return <FileText size={12} />;
  }
}

type Props = {
  id: number;
  type: string;
  payload: string;
  proxy: string;
  size: number;
  extra?: RuleExtra;
  provider?: RuleProviderIndex;
};

/** GeoSite/GeoIP 的条目数后端直接给，RuleSet 的要去提供商表里查 */
function getEntryCount({
  type,
  payload,
  size,
  provider,
}: {
  type: string;
  payload: string;
  size: number;
  provider?: RuleProviderIndex;
}): number | undefined {
  if ((type === 'GeoSite' || type === 'GeoIP') && size >= 0) {
    return size;
  }
  if (type === 'RuleSet') {
    return provider?.byName?.[payload]?.ruleCount;
  }
  return undefined;
}

function Rule({ type, payload, proxy, id, size, extra, provider }: Props) {
  const { t } = useTranslation();
  const disabled = extra?.disabled ?? false;
  const entryCount = getEntryCount({ type, payload, size, provider });

  const hitTitle = extra
    ? extra.hitCount > 0
      ? t('rule_hit_tip', {
          count: extra.hitCount,
          time: formatDistanceToNow(new Date(extra.hitAt), { addSuffix: true }),
        })
      : t('rule_never_hit')
    : undefined;

  return (
    <div className={cx(s.rule, { [s.disabled]: disabled })}>
      {/* 桌面端在最左边，窄屏靠 .switch 的 order 拨到行尾 */}
      <div className={s.index}>{id}</div>

      <div className={s.main}>
        <div className={s.payloadRow}>
          <div className={s.payload}>{payload}</div>
          {typeof entryCount === 'number' ? (
            <div className={s.entryCount}>{t('rule_entry_count', { count: entryCount })}</div>
          ) : null}
        </div>

        <div className={s.metaRow}>
          <span className={s.typeTag}>
            {getIconFor(type)}
            <span>{type}</span>
          </span>
          <span
            className={s.proxy}
            style={{ color: proxyColor[proxy] ?? 'var(--color-focus-blue)' }}
          >
            {proxy}
          </span>
          {extra ? (
            <span className={s.hitInfo} title={hitTitle}>
              <Activity size={12} />
              {extra.hitCount}
            </span>
          ) : null}
        </div>
      </div>
    </div>
  );
}

// 上千行的虚拟列表，滚动时不该因为父组件重渲染而整屏重算
export default React.memo(Rule);
