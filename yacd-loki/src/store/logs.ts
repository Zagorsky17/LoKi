import { atom } from 'jotai';

import type { Log } from '~/types';

const LogSize = 300;

/** 日志搜索词。过滤在组件里做，见 modules/logs/hooks 的 useFilteredLogs */
export const logFilterText = atom('');

/**
 * 环形缓冲区。数组本身就地改、每次只换外层对象，免得每条日志复制一份 300 长的数组；
 * 靠外层对象的 identity 变化通知 logsForDisplayAtom 重算。
 */
const logsBufferAtom = atom<{ logs: Log[]; tail: number }>({ logs: [], tail: -1 });

/** 把环形缓冲区按时间顺序摊平 */
export const logsForDisplayAtom = atom((get) => {
  const { logs, tail } = get(logsBufferAtom);
  const x: Log[] = [];
  if (logs.length === LogSize) {
    for (let i = tail + 1; i < LogSize; i++) {
      x.push(logs[i]);
    }
  }
  for (let i = 0; i <= tail; i++) {
    x.push(logs[i]);
  }
  return x;
});

export const appendLogAtom = atom(null, (get, set, log: Log) => {
  const { logs, tail: tailCurr } = get(logsBufferAtom);
  const tail = tailCurr >= LogSize - 1 ? 0 : tailCurr + 1;
  // mutate intentionally for performance
  logs[tail] = log;
  set(logsBufferAtom, { logs, tail });
});

export const clearLogsAtom = atom(null, (_get, set) => {
  set(logsBufferAtom, { logs: [], tail: -1 });
});
