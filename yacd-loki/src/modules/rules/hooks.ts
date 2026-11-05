import { useMutation, useQueryClient, useSuspenseQuery } from '@tanstack/react-query';
import { useAtom } from 'jotai';
import * as React from 'react';

import {
  fetchRuleProviders,
  refreshRuleProviderByName,
  updateRuleProviders,
} from '~/api/rule-provider';
import { fetchRules } from '~/api/rules';
import { ruleFilterText } from '~/store/rules';
import type { ClashAPIConfig } from '~/types';

import type { RulesTabKey } from './utils';

const { useCallback, useMemo, useState } = React;

export function useUpdateRuleProviderItem(
  name: string,
  apiConfig: ClashAPIConfig,
): [() => void, boolean] {
  const queryClient = useQueryClient();
  const { mutate, isPending } = useMutation({
    mutationFn: refreshRuleProviderByName,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['/providers/rules'] });
    },
  });
  const refresh = useCallback(() => mutate({ name, apiConfig }), [mutate, name, apiConfig]);
  return [refresh, isPending];
}

export function useUpdateAllRuleProviderItems(apiConfig: ClashAPIConfig): [() => void, boolean] {
  const queryClient = useQueryClient();
  const { data: provider } = useRuleProviderQuery(apiConfig);
  const { mutate, isPending } = useMutation({
    mutationFn: updateRuleProviders,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['/providers/rules'] });
    },
  });
  const refreshAll = useCallback(
    () => mutate({ names: provider.names, apiConfig }),
    [mutate, provider.names, apiConfig],
  );
  return [refreshAll, isPending];
}

export function useRuleProviderQuery(apiConfig: ClashAPIConfig) {
  return useSuspenseQuery({
    queryKey: ['/providers/rules', apiConfig],
    queryFn: () => fetchRuleProviders('/providers/rules', apiConfig),
  });
}

export function useRuleAndProvider(apiConfig: ClashAPIConfig) {
  const { data: rules, isFetching } = useSuspenseQuery({
    queryKey: ['/rules', apiConfig],
    queryFn: () => fetchRules('/rules', apiConfig),
  });
  const { data: provider } = useRuleProviderQuery(apiConfig);

  const [filterText] = useAtom(ruleFilterText);

  // 规则表动辄上千条，过滤结果必须缓存住：不然每次渲染都重算一遍，
  // 而且新数组会让下游的 memo 全部失效
  return useMemo(() => {
    if (filterText === '') {
      return { rules, provider, isFetching };
    }
    const f = filterText.toLowerCase();
    return {
      rules: rules.filter((r) => r.payload.toLowerCase().indexOf(f) >= 0),
      isFetching,
      provider: {
        byName: provider.byName,
        names: provider.names.filter((t) => t.toLowerCase().indexOf(f) >= 0),
      },
    };
  }, [rules, provider, filterText, isFetching]);
}

export function useRulesPage(apiConfig: ClashAPIConfig) {
  const { rules, provider } = useRuleAndProvider(apiConfig);
  // 标签出不出现看提供商总数，不看过滤结果——搜索不该把整个标签搞消失
  const { data: allProviders } = useRuleProviderQuery(apiConfig);
  const providerCount = allProviders.names.length;

  const [activeTab, setActiveTab] = useState<RulesTabKey>('rules');
  const effectiveTab: RulesTabKey = providerCount > 0 ? activeTab : 'rules';

  return {
    rules,
    provider,
    providerCount,
    activeTab: effectiveTab,
    setActiveTab,
    isRulesTab: effectiveTab === 'rules',
  };
}
