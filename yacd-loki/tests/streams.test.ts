import { expect, test } from 'bun:test';

import { fetchData as fetchMemory } from '../src/api/memory';
import { fetchData as fetchTraffic } from '../src/api/traffic';

const config = { baseURL: 'https://ignored.example', secret: 'synthetic-secret' };

for (const [name, fetchData, sample, field] of [
  ['traffic', fetchTraffic, { up: 7, down: 9 }, 'up'],
  ['memory', fetchMemory, { inuse: 7, oslimit: 9 }, 'inuse'],
] as const) {
  test(`${name} uses only WebSocket, rejects malformed samples and reconnects while subscribed`, () => {
    const originalWindow = globalThis.window;
    const originalSocket = globalThis.WebSocket;
    const originalFetch = globalThis.fetch;
    const originalTimer = globalThis.setTimeout;
    let retry: (() => void) | undefined;
    const sockets: FakeSocket[] = [];
    class FakeSocket {
      handlers: Record<string, ((event?: any) => void)[]> = {};
      closed = false;
      constructor(public url: string) { sockets.push(this); }
      addEventListener(type: string, callback: (event?: any) => void) {
        (this.handlers[type] ??= []).push(callback);
      }
      emit(type: string, event?: any) { this.handlers[type]?.forEach((callback) => callback(event)); }
      close() { this.closed = true; this.emit('close'); }
    }
    Object.defineProperty(globalThis, 'window', { configurable: true, value: { location: { protocol: 'https:', origin: 'https://router.example:9091' } } });
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    globalThis.fetch = async () => { throw new Error('HTTP stream fallback is forbidden'); };
    globalThis.setTimeout = ((callback: () => void) => { retry = callback; return 1; }) as typeof setTimeout;
    try {
      const stream = fetchData(config);
      const values: number[] = [];
      const unsubscribe = stream.subscribe((value: any) => values.push(value[field]));
      expect(sockets[0].url).toBe(`wss://router.example:9091/cgi-bin/luci/loki-gateway/api/${name}`);
      sockets[0].emit('message', { data: JSON.stringify(sample) });
      sockets[0].emit('message', { data: 'synthetic-secret{' });
      sockets[0].emit('message', { data: JSON.stringify({ [field]: -1 }) });
      expect(values).toEqual([7]);
      sockets[0].close();
      expect(retry).toBeDefined();
      const reconnect = retry!;
      retry = undefined;
      reconnect();
      expect(sockets).toHaveLength(2);
      unsubscribe();
      expect(sockets[1].closed).toBe(true);
      expect(retry).toBeUndefined();
    } finally {
      Object.defineProperty(globalThis, 'window', { configurable: true, value: originalWindow });
      globalThis.WebSocket = originalSocket;
      globalThis.fetch = originalFetch;
      globalThis.setTimeout = originalTimer;
    }
  });
}
