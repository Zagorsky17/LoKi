import { ClashAPIConfig } from '~/types';

import { buildWebSocketURL } from '../misc/request-helper';

const endpoint = '/memory';

const Size = 150;
let ws: WebSocket | undefined;
let retry: ReturnType<typeof setTimeout> | undefined;
let lastConfig: ClashAPIConfig;

const memory = {
  labels: Array(Size)
    .fill(0)
    .map((_, i) => Date.now() - (Size - i) * 1000),
  inuse: Array(Size).fill(null),
  oslimit: Array(Size).fill(null),

  size: Size,
  subscribers: [] as Array<(o: { inuse: number; oslimit: number }) => void>,
  appendData(o: { inuse: number; oslimit: number }) {
    this.inuse.shift();
    this.oslimit.shift();
    this.labels.shift();

    const l = Date.now();
    this.inuse.push(o.inuse);
    this.oslimit.push(o.oslimit);
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
  if (ws || retry) return memory;
  const socket = new WebSocket(buildWebSocketURL(apiConfig, endpoint));
  ws = socket;
  socket.addEventListener('error', () => socket.close());
  socket.addEventListener('close', () => {
    if (ws !== socket) return;
    ws = undefined;
    if (memory.subscribers.length) {
      retry = setTimeout(() => {
        retry = undefined;
        fetchData(lastConfig);
      }, 5000);
    }
  });
  socket.addEventListener('message', (event) => {
    try {
      const value = JSON.parse(event.data);
      if (Number.isFinite(value.inuse) && Number.isFinite(value.oslimit) &&
          value.inuse >= 0 && value.oslimit >= 0)
        memory.appendData(value);
    } catch {
      // Ignore malformed controller samples without exposing their payload.
    }
  });
  return memory;
}

export { fetchData };
