import { useAtom, useSetAtom } from 'jotai';
import * as React from 'react';

import { fetchLogs, stop as stopLogs } from '~/api/logs';
import { appendLogAtom, logFilterText } from '~/store/logs';
import { ClashAPIConfig, Log } from '~/types';

import { LOGS_SCROLL_BOTTOM_THRESHOLD } from './utils';

const { useCallback, useEffect, useMemo, useRef, useState } = React;

type UpdateAppConfigFn = (name: string, value: unknown) => void;

/** 搜索词是防抖过的，过滤结果缓存住，免得每条新日志进来都重扫一遍 */
export function useFilteredLogs(logs: Log[]) {
  const [filterText] = useAtom(logFilterText);
  return useMemo(() => {
    if (filterText === '') return logs;
    const f = filterText.toLowerCase();
    return logs.filter((log) => log.payload.toLowerCase().indexOf(f) >= 0);
  }, [logs, filterText]);
}

export function useLogsPage({
  logLevel,
  apiConfig,
  logs,
  logStreamingPaused,
  updateAppConfig,
}: {
  logLevel: string;
  apiConfig: ClashAPIConfig;
  logs: Log[];
  logStreamingPaused: boolean;
  updateAppConfig: UpdateAppConfigFn;
}) {
  const toggleIsRefreshPaused = useCallback(() => {
    if (!logStreamingPaused) stopLogs();
    updateAppConfig('logStreamingPaused', !logStreamingPaused);
  }, [logStreamingPaused, updateAppConfig]);

  // useSetAtom 返回的 setter 引用稳定，可以直接当 effect 依赖
  const appendLog = useSetAtom(appendLogAtom);

  useEffect(() => {
    if (logStreamingPaused) return;
    const unsubscribe = fetchLogs({ ...apiConfig, logLevel }, appendLog);
    return () => {
      unsubscribe?.();
    };
  }, [apiConfig, logLevel, appendLog, logStreamingPaused]);

  const scrollRef = useRef<HTMLDivElement>(null);
  const [isAtBottom, setIsAtBottom] = useState(true);

  const scrollToBottom = useCallback(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, []);

  // 贴着底看的时候才自动跟随，用户往回翻了就别抢滚动位置
  useEffect(() => {
    if (isAtBottom) {
      scrollToBottom();
    }
  }, [logs, isAtBottom, scrollToBottom]);

  const onScroll = useCallback((e: React.UIEvent<HTMLDivElement>) => {
    const { scrollTop, scrollHeight, clientHeight } = e.currentTarget;
    const atBottom = scrollHeight - scrollTop - clientHeight < LOGS_SCROLL_BOTTOM_THRESHOLD;
    setIsAtBottom(atBottom);
  }, []);

  return {
    toggleIsRefreshPaused,
    scrollRef,
    isAtBottom,
    scrollToBottom,
    onScroll,
  };
}
