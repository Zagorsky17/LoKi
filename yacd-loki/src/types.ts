export type ClashAPIConfig = {
  baseURL: string;
  secret?: string;
};

export type LogsAPIConfig = ClashAPIConfig & { logLevel: string };

/** 一条日志。`/logs` 是 WebSocket 流，不进自研 store，见 store/logs.ts */
export type Log = {
  time: string;
  even: boolean;
  payload: string;
  type: string;
  id: string;
};
