import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { socket } from '../socket.service';

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static instances: FakeWebSocket[] = [];

  readyState = FakeWebSocket.CONNECTING;
  private listeners = new Map<string, Array<(event: Event) => void>>();

  constructor(_url: string) {
    FakeWebSocket.instances.push(this);
  }

  addEventListener(type: string, listener: (event: Event) => void) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  emit(type: string) {
    for (const listener of this.listeners.get(type) || []) {
      listener(new Event(type));
    }
  }

  close() {}
  send() {}
}

describe('socket service', () => {
  beforeEach(() => {
    socket.resetAll();
    FakeWebSocket.instances = [];
    vi.stubGlobal('WebSocket', FakeWebSocket);
  });

  afterEach(() => {
    socket.resetAll();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('never writes the token it connects with', async () => {
    vi.useFakeTimers();
    const lines: string[] = [];
    for (const level of ['log', 'debug', 'info', 'warn', 'error'] as const) {
      vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
        lines.push(args.map(String).join(' '));
      });
    }

    socket.subscribe('ws://router.test/traffic?token=hunter2', vi.fn());
    FakeWebSocket.instances[0].emit('open');
    FakeWebSocket.instances[0].emit('error');
    FakeWebSocket.instances[0].emit('close');
    await vi.advanceTimersByTimeAsync(1000);
    socket.resetAll();
    vi.restoreAllMocks();

    const written = lines.join('\n');
    expect(written).toContain('ws://router.test/traffic');
    expect(written).not.toContain('hunter2');
  });

  it('keeps the initial subscriber when the first connection fails', () => {
    const onError = vi.fn();

    socket.subscribe('ws://router.test', vi.fn(), onError);
    FakeWebSocket.instances[0].emit('error');

    expect(onError).toHaveBeenCalledOnce();
  });

  it('reconnects a subscribed socket after the server closes it', async () => {
    vi.useFakeTimers();

    socket.subscribe('ws://router.test', vi.fn());
    FakeWebSocket.instances[0].emit('close');
    await vi.advanceTimersByTimeAsync(1000);

    expect(FakeWebSocket.instances).toHaveLength(2);
  });

  it('waits longer after every failed reconnect', async () => {
    vi.useFakeTimers();

    socket.subscribe('ws://router.test', vi.fn());
    FakeWebSocket.instances[0].emit('close');
    await vi.advanceTimersByTimeAsync(1000);
    FakeWebSocket.instances[1].emit('close');
    await vi.advanceTimersByTimeAsync(1000);

    expect(FakeWebSocket.instances).toHaveLength(2);

    await vi.advanceTimersByTimeAsync(1000);

    expect(FakeWebSocket.instances).toHaveLength(3);
  });

  it('starts over from the short delay once a socket connects', async () => {
    vi.useFakeTimers();

    socket.subscribe('ws://router.test', vi.fn());
    FakeWebSocket.instances[0].emit('close');
    await vi.advanceTimersByTimeAsync(1000);
    FakeWebSocket.instances[1].emit('open');
    FakeWebSocket.instances[1].emit('close');
    await vi.advanceTimersByTimeAsync(1000);

    expect(FakeWebSocket.instances).toHaveLength(3);
  });
});
