import type { RuleProvider } from '~/api/rule-provider';
import type { RuleItem } from '~/api/rules';
import type { ClashAPIConfig } from '~/types';

export type RuleProviderIndex = {
  byName: Record<string, RuleProvider>;
  names: string[];
};

export type RulesTabKey = 'rules' | 'providers';

export type RulesRowProps = {
  /** 规则标签页的数据；提供商标签页下为 null */
  rules: RuleItem[] | null;
  provider: RuleProviderIndex;
  apiConfig: ClashAPIConfig;
};

// 虚拟列表要求定高。两个数字都按「内容最多的那一行」定：
// 规则行是 序号 + 两行内容（payload 长了会折行占两行），提供商行多一行元信息
export const RULE_ROW_HEIGHT = 88;
export const PROVIDER_ROW_HEIGHT = 100;
