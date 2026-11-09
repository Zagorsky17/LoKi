import * as React from 'react';
import { useTranslation } from 'react-i18next';
import { RowComponentProps, List as VirtualList } from 'react-window';

import { useRulesPage, useUpdateAllRuleProviderItems } from '~/modules/rules/hooks';
import { PROVIDER_ROW_HEIGHT, RULE_ROW_HEIGHT, type RulesRowProps } from '~/modules/rules/utils';
import { ClashAPIConfig } from '~/types';

import Rule from './Rule';
import { RuleProviderItem } from './RuleProviderItem';
import s from './Rules.module.scss';
import { RulesHeader } from './RulesHeader';

function Row({ index, style, rules, provider, apiConfig }: RowComponentProps<RulesRowProps>) {
  if (!rules) {
    const item = provider.byName[provider.names[index]];
    return (
      <div style={style} className={s.row}>
        <RuleProviderItem apiConfig={apiConfig} {...item} />
      </div>
    );
  }

  return (
    <div style={style} className={s.row}>
      <Rule {...rules[index]} provider={provider} />
    </div>
  );
}

type RulesProps = {
  apiConfig: ClashAPIConfig;
};

export default function Rules({ apiConfig }: RulesProps) {
  const { t } = useTranslation();
  const { rules, provider, providerCount, activeTab, setActiveTab, isRulesTab } =
    useRulesPage(apiConfig);
  const [updateAllProviders, isUpdatingProviders] = useUpdateAllRuleProviderItems(apiConfig);

  const rowCount = isRulesTab ? rules.length : provider.names.length;

  // rowProps 每次渲染新建对象会让所有行跟着重渲染，虚拟列表就白做了
  const rowProps = React.useMemo<RulesRowProps>(
    () => ({ rules: isRulesTab ? rules : null, provider, apiConfig }),
    [isRulesTab, rules, provider, apiConfig],
  );

  const rowHeight = React.useCallback(
    () => (isRulesTab ? RULE_ROW_HEIGHT : PROVIDER_ROW_HEIGHT),
    [isRulesTab],
  );

  const rowKey = React.useCallback(
    (index: number, { rules, provider }: RulesRowProps) =>
      rules ? rules[index].id : provider.names[index],
    [],
  );

  return (
    <div className={s.page}>
      <RulesHeader
        activeTab={activeTab}
        setActiveTab={setActiveTab}
        ruleCount={rules.length}
        providerCount={providerCount}
        visibleProviderCount={provider.names.length}
        onUpdateAllProviders={updateAllProviders}
        isUpdatingProviders={isUpdatingProviders}
      />

      <div className={s.listArea}>
        <div className={s.card}>
          <div className={s.listWrap}>
            {rowCount === 0 ? (
              <div className={s.empty}>
                <span className={s.emptyTitle}>
                  {t(isRulesTab ? 'rules_empty_title' : 'rule_providers_empty_title')}
                </span>
                <span className={s.emptyHint}>{t('rules_empty_hint')}</span>
              </div>
            ) : (
              <VirtualList
                style={{ height: '100%', width: '100%' }}
                rowCount={rowCount}
                rowHeight={rowHeight}
                rowComponent={Row}
                rowKey={rowKey}
                rowProps={rowProps}
              />
            )}
          </div>

          <div className={s.footer}>
            <span>{t('rules_shown', { count: rowCount })}</span>
          </div>
        </div>
      </div>
    </div>
  );
}
