import { pad0 } from '~/misc/utils';
import { Log, LogsAPIConfig } from '~/types';

import { buildLogsWebSocketURL } from '../misc/request-helper';

type AppendLogFn = (x: Log) => void;
enum WebSocketReadyState {
  Connecting = 0,
  Open = 1,
  Closing = 2,
  Closed = 3,
}

const endpoint = '/logs';

const getRandomStr = () => {
  return Math.floor((1 + Math.random()) * 0x10000).toString(16);
};

let even = false;
let ws: WebSocket | undefined;
let currentConnStr: string;

type UnsubscribeFn = () => void;
// the WS/fetch stream is a module-level singleton so switching away from and
// back to the Logs page doesn't tear down and re-handshake the connection —
// only unsubscribe here, the connection itself outlives any single mount
const subscribers: AppendLogFn[] = [];

function broadcast(log: Log) {
  subscribers.forEach((listener) => listener(log));
}

function appendData(s: string) {
  let o: Partial<Log>;
  try {
    o = JSON.parse(s);
  } catch (err) {
    console.warn('Invalid gateway log entry');
    return;
  }

  const now = new Date();
  const time = formatDate(now);
  o.time = time;
  o.id = +now - 0 + getRandomStr();
  o.even = even = !even;
  broadcast(o as Log);
}

function formatDate(d: Date) {
  // 19-03-09 12:45
  const YY = d.getFullYear() % 100;
  const MM = pad0(d.getMonth() + 1, 2);
  const dd = pad0(d.getDate(), 2);
  const HH = pad0(d.getHours(), 2);
  const mm = pad0(d.getMinutes(), 2);
  const ss = pad0(d.getSeconds(), 2);
  return `${YY}-${MM}-${dd} ${HH}:${mm}:${ss}`;
}

/** loose hashing of the connection configuration */
function makeConnStr(c: LogsAPIConfig) {
  const keys = Object.keys(c);
  keys.sort();
  return keys.map((k) => c[k as keyof LogsAPIConfig]).join('|');
}

function isConnectionLive() {
  return ws && ws.readyState === WebSocketReadyState.Open;
}

function teardown() {
  if (ws) {
    ws.close();
    ws = undefined;
  }
}

function subscribe(listener: AppendLogFn): UnsubscribeFn {
  subscribers.push(listener);
  return function unsubscribe() {
    const idx = subscribers.indexOf(listener);
    if (idx !== -1) subscribers.splice(idx, 1);
    if (subscribers.length === 0) teardown();
  };
}

function openConnection(apiConfig: LogsAPIConfig) {
  const url = buildLogsWebSocketURL(apiConfig, endpoint);
  const socket = new WebSocket(url);
  ws = socket;
  socket.addEventListener('error', () => {
    if (ws === socket) {
      socket.close();
      ws = undefined;
    }
  });
  socket.addEventListener('close', () => {
    if (ws === socket) ws = undefined;
  });
  socket.addEventListener('message', function (event) {
    appendData(event.data);
  });
}

export function fetchLogs(
  apiConfig: LogsAPIConfig,
  appendLog: AppendLogFn,
): UnsubscribeFn | undefined {
  if (apiConfig.logLevel === 'uninit') return undefined;

  const connStr = makeConnStr(apiConfig);
  if (isConnectionLive() && connStr === currentConnStr) {
    return subscribe(appendLog);
  }

  teardown();
  currentConnStr = connStr;
  openConnection(apiConfig);
  return subscribe(appendLog);
}

/** explicitly stop streaming, e.g. when the user hits "pause" */
export function stop() {
  teardown();
}

/** explicitly force a fresh connection, e.g. after changing log level or hitting "resume" */
