import { ClashAPIConfig } from '~/types';

import { buildWebSocketURL } from '../misc/request-helper';

const endpoint = '/traffic';

const Size = 150;
let ws: WebSocket | undefined;
let retry: ReturnType<typeof setTimeout> | undefined;
let lastConfig: ClashAPIConfig;

const traffic = {
  labels: Array(Size)
    .fill(0)
    .map((_, i) => Date.now() - (Size - i) * 1000),
  up: Array(Size).fill(null),
  down: Array(Size).fill(null),

  size: Size,
  subscribers: [] as Array<(o: { up: number; down: number }) => void>,
  appendData(o: { up: number; down: number }) {
    this.up.shift();
    this.down.shift();
    this.labels.shift();

    const l = Date.now();
    this.up.push(o.up);
    this.down.push(o.down);
    this.labels.push(l);

    this.subscribers.forEach((f) => f(o));
  },

  subscribe(listener: (x: any) => void) {
    this.subscribers.push(listener);
    if (!ws && !retry && lastConfig) fetchData(lastConfig);
    return () => {
      const idx = this.subscribers.indexOf(listener);
      if (idx >= 0) this.subscribers.splice(idx, 1);
      if (this.subscribers.length === 0) {
        if (retry) clearTimeout(retry);
        retry = undefined;
        const current = ws;
        ws = undefined;
        current?.close();
      }
    };
  },
};

function fetchData(apiConfig: ClashAPIConfig) {
  lastConfig = apiConfig;
  if (ws || retry) return traffic;
  const socket = new WebSocket(buildWebSocketURL(apiConfig, endpoint));
  ws = socket;
  socket.addEventListener('error', () => socket.close());
  socket.addEventListener('close', () => {
    if (ws !== socket) return;
    ws = undefined;
    if (traffic.subscribers.length) {
      retry = setTimeout(() => {
        retry = undefined;
        fetchData(lastConfig);
      }, 5000);
    }
  });
  socket.addEventListener('message', (event) => {
    try {
      const value = JSON.parse(event.data);
      if (Number.isFinite(value.up) && Number.isFinite(value.down) &&
          value.up >= 0 && value.down >= 0)
        traffic.appendData(value);
    } catch {
      // Ignore malformed controller samples without exposing their payload.
    }
  });
  return traffic;
}

export { fetchData };
