import { afterEach, beforeEach, expect, it, vi } from 'vitest';
const mocks = vi.hoisted(() => ({ callUbus: vi.fn() }));
vi.mock('../callUbus', () => ({ callUbus: mocks.callUbus }));
import { executeShellCommand, readOnlyLokiArgs } from '../executeShellCommand';

const ID = 'a'.repeat(64);
let commandReply: unknown;

function protocol({
  method,
  params,
}: {
  method: string;
  params: Record<string, unknown>;
}) {
  if (method.endsWith('_prepare'))
    return { success: true, data: { success: true, id: ID } };
  if (method === 'rpc_read' || method === 'rpc_write')
    return { success: true, data: { pending: true, result_id: ID } };
  if (params.part === 'release')
    return { success: true, data: { success: true } };
  if (params.part === 'status')
    return {
      success: true,
      data: { success: true, pending: false, response: commandReply },
    };
  throw new Error('Unexpected RPC result request');
}

beforeEach(() => {
  commandReply = { stdout: '{}', stderr: '', code: 0 };
  mocks.callUbus.mockReset().mockImplementation(protocol);
  (globalThis as unknown as { fs: unknown }).fs = { exec: vi.fn() };
});
afterEach(() => vi.useRealTimers());

it('rejects a free executable without calling any executor or RPC', async () => {
  expect(
    await executeShellCommand({ command: '/bin/sh', args: ['-c', 'id'] }),
  ).toEqual({ code: 1, stdout: '', stderr: 'The executable is not allowed' });
  expect(mocks.callUbus).not.toHaveBeenCalled();
  expect(fs.exec).not.toHaveBeenCalled();
});

it('routes snapshots, diagnostics and checks through prepared read RPC', async () => {
  for (const args of [
    ['get_ui_state'],
    ['get_system_info'],
    ['check_logs'],
    ['report', 'masked', '{}'],
    ['installer_status', '0'],
    ['installer_start', 'check', '', '0', 'ru'],
    ['clash_api', 'GET', '/proxies', ''],
  ]) {
    expect(readOnlyLokiArgs(args)).toBe(true);
    await executeShellCommand({
      command: '/usr/bin/loki',
      args,
      timeout: null,
    });
    expect(mocks.callUbus).toHaveBeenCalledWith(
      expect.objectContaining({
        method: 'rpc_read_prepare',
        params: { argv: args },
        retryUnavailable: false,
        nobatch: true,
      }),
    );
    expect(mocks.callUbus).toHaveBeenCalledWith(
      expect.objectContaining({
        method: 'rpc_read',
        params: { argv: args, request_id: ID },
        retryUnavailable: false,
      }),
    );
  }
  expect(fs.exec).not.toHaveBeenCalled();
});

it('queues the dashboard snapshots until the exclusive large result has been released', async () => {
  let active = false;
  let finishFirst!: () => void;
  let entered!: () => void;
  const started = new Promise<void>((resolve) => {
    entered = resolve;
  });
  const finish = new Promise<void>((resolve) => {
    finishFirst = resolve;
  });
  let invocations = 0;
  mocks.callUbus.mockImplementation(async (options) => {
    if (options.method.endsWith('_prepare')) {
      if (active)
        return {
          success: true,
          data: {
            success: false,
            code: 16,
            message: 'The RPC command limit is busy',
          },
        };
      active = true;
    }
    if (options.method === 'rpc_read' && ++invocations === 1) {
      entered();
      await finish;
    }
    if (options.params.part === 'release') active = false;
    return protocol(options);
  });
  const first = executeShellCommand({
    command: '/usr/bin/loki',
    args: ['clash_api', 'GET', '/proxies', ''],
  });
  await started;
  const second = executeShellCommand({
    command: '/usr/bin/loki',
    args: ['clash_api', 'GET', '/providers/proxies', ''],
  });
  finishFirst();
  expect(
    (await Promise.all([first, second])).map((reply) => reply.code),
  ).toEqual([0, 0]);
  expect(active).toBe(false);
});

it('routes formatted report text through the read role without granting controls in other arguments', async () => {
  const args = ['report', 'masked', '✓ Service — OK\n\tDNS: OK\r\n'];
  expect(readOnlyLokiArgs(args)).toBe(true);
  await executeShellCommand({ command: '/usr/bin/loki', args });
  expect(mocks.callUbus).toHaveBeenCalledWith(
    expect.objectContaining({
      method: 'rpc_read_prepare',
      params: { argv: args },
    }),
  );
  for (const invalid of [
    ['report', 'masked\n', 'text'],
    ['report', 'masked', 'text\0'],
    ['report', 'masked', 'text\x1b[31m'],
    ['report', 'masked', 'text\x7f'],
    ['get_ui_state\n'],
  ])
    expect(readOnlyLokiArgs(invalid)).toBe(false);
});

it('lets a service action finish while a large snapshot is waiting', async () => {
  let entered!: () => void;
  let finishRead!: () => void;
  const started = new Promise<void>((resolve) => {
    entered = resolve;
  });
  const finish = new Promise<void>((resolve) => {
    finishRead = resolve;
  });
  mocks.callUbus.mockImplementation(async (options) => {
    if (options.method === 'rpc_read') {
      entered();
      await finish;
    }
    return protocol(options);
  });
  const read = executeShellCommand({
    command: '/usr/bin/loki',
    args: ['clash_api', 'GET', '/proxies', ''],
  });
  await started;
  try {
    expect(
      (
        await executeShellCommand({
          command: '/usr/bin/loki',
          args: ['enable'],
        })
      ).code,
    ).toBe(0);
  } finally {
    finishRead();
    await read;
  }
});

it('does not start a queued request after its deadline and releases the queue', async () => {
  vi.useFakeTimers();
  let entered!: () => void;
  let finishFirst!: () => void;
  const started = new Promise<void>((resolve) => {
    entered = resolve;
  });
  const finish = new Promise<void>((resolve) => {
    finishFirst = resolve;
  });
  let invocations = 0;
  mocks.callUbus.mockImplementation(async (options) => {
    if (options.method === 'rpc_read' && ++invocations === 1) {
      entered();
      await finish;
    }
    return protocol(options);
  });
  const args = ['clash_api', 'GET', '/proxies', ''];
  const first = executeShellCommand({ command: '/usr/bin/loki', args });
  await started;
  const expired = executeShellCommand({
    command: '/usr/bin/loki',
    args,
    timeout: 10,
  });
  vi.setSystemTime(Date.now() + 20);
  finishFirst();
  expect((await first).code).toBe(0);
  expect((await expired).stderr).toContain('timed out before execution');
  expect(invocations).toBe(1);
  expect(
    (await executeShellCommand({ command: '/usr/bin/loki', args })).code,
  ).toBe(0);
});

it('keeps mutations, active GET probes and raw exports behind prepared write RPC', async () => {
  for (const args of [
    ['installer_start', 'update', '', '0', 'ru'],
    ['report', 'raw', '{}'],
    ['show_config', 'raw'],
    ['clash_api', 'PUT', '/proxies/main', '{}'],
    ['clash_api', 'GET', '/proxies/Node/link', ''],
    ['clash_api', 'GET', '/proxies/Node/exit?timeout=1000', ''],
    [
      'clash_api',
      'GET',
      '/proxies/Node/delay?url=https%3A%2F%2Fexample.invalid&timeout=1000',
      '',
    ],
    ['get_system_info', 'extra'],
    ['installer_status', '0; touch marker'],
    ['clash_api', 'GET', '/proxies\nPUT /', ''],
  ]) {
    expect(readOnlyLokiArgs(args)).toBe(false);
    await executeShellCommand({
      command: '/usr/bin/loki',
      args,
      timeout: null,
    });
    expect(mocks.callUbus).toHaveBeenCalledWith(
      expect.objectContaining({
        method: 'rpc_write_prepare',
        params: { argv: args },
      }),
    );
    expect(mocks.callUbus).toHaveBeenCalledWith(
      expect.objectContaining({
        method: 'rpc_write',
        params: { argv: args, request_id: ID },
      }),
    );
  }
  expect(fs.exec).not.toHaveBeenCalled();
});

it('does not retry or fall back after preparation is denied or unavailable', async () => {
  mocks.callUbus.mockResolvedValue({
    success: false,
    message: 'denied',
    unavailable: true,
  });
  expect(
    await executeShellCommand({ command: '/usr/bin/loki', args: ['enable'] }),
  ).toEqual({ code: 1, stdout: '', stderr: 'denied' });
  expect(mocks.callUbus).toHaveBeenCalledTimes(1);
  expect(fs.exec).not.toHaveBeenCalled();
});

it('recovers a lost start reply through the known prepared id without submitting a second write', async () => {
  mocks.callUbus.mockImplementation((options) =>
    options.method === 'rpc_write'
      ? { success: false, message: 'connection lost', unavailable: false }
      : protocol(options),
  );
  expect(
    await executeShellCommand({ command: '/usr/bin/loki', args: ['enable'] }),
  ).toEqual({ code: 0, stdout: '{}', stderr: '' });
  expect(
    mocks.callUbus.mock.calls.filter(
      ([options]) => options.method === 'rpc_write_prepare',
    ),
  ).toHaveLength(1);
  expect(
    mocks.callUbus.mock.calls.filter(
      ([options]) => options.method === 'rpc_write',
    ),
  ).toHaveLength(1);
});

it('does not generate a fresh intent after an unknown or expired outcome', async () => {
  mocks.callUbus.mockImplementation((options) =>
    options.params.part === 'status'
      ? { success: true, data: { success: false, message: 'expired outcome' } }
      : protocol(options),
  );
  const reply = await executeShellCommand({
    command: '/usr/bin/loki',
    args: ['enable'],
  });
  expect(reply.code).toBe(1);
  expect(reply.stdout).toBe('');
  expect(reply.stderr).toBe('expired outcome');
  expect(
    mocks.callUbus.mock.calls.filter(([options]) =>
      options.method.endsWith('_prepare'),
    ),
  ).toHaveLength(1);
  expect(
    mocks.callUbus.mock.calls.filter(
      ([options]) => options.method === 'rpc_write',
    ),
  ).toHaveLength(1);
});

it('keeps diagnostics longer than sixty seconds in short independently authorized polling requests', async () => {
  vi.useFakeTimers();
  const started = Date.now();
  mocks.callUbus.mockImplementation((options) => {
    expect(options.timeoutMs).toBeLessThanOrEqual(15000);
    if (options.params.part === 'status' && Date.now() - started < 61000) {
      return { success: true, data: { success: true, pending: true } };
    }
    return protocol(options);
  });
  const result = executeShellCommand({
    command: '/usr/bin/loki',
    args: ['check_dns'],
    timeout: 180000,
  });
  await vi.advanceTimersByTimeAsync(61000);
  expect(await result).toEqual({ code: 0, stdout: '{}', stderr: '' });
  expect(
    mocks.callUbus.mock.calls.filter(
      ([options]) => options.params.part === 'status',
    ).length,
  ).toBeGreaterThan(600);
});

it('rejects malformed terminal replies instead of treating an absent exit code as success', async () => {
  for (const data of [
    {},
    { stdout: '{}', stderr: '' },
    { stdout: '{}', stderr: '', code: -1 },
  ]) {
    commandReply = data;
    expect(
      await executeShellCommand({
        command: '/usr/bin/loki',
        args: ['show_version'],
      }),
    ).toEqual({ code: 1, stdout: '', stderr: 'Invalid RPC response' });
  }
  expect(fs.exec).not.toHaveBeenCalled();
});

it('reassembles a large UTF-8 report and releases its private result', async () => {
  const stdout = 'x'.repeat(32767) + 'Привет 🦊' + 'x'.repeat(130000);
  const parts = {
    stdout: new TextEncoder().encode(stdout),
    stderr: new TextEncoder().encode('detail'),
  };
  commandReply = { code: 0, stdout: '', stderr: '', result_id: ID };
  mocks.callUbus.mockImplementation((options) => {
    if (options.params.part !== 'stdout' && options.params.part !== 'stderr')
      return protocol(options);
    const { part, offset } = options.params;
    const content = parts[part as keyof typeof parts];
    const chunk = content.slice(offset, offset + 32768);
    return {
      success: true,
      data: {
        success: true,
        data: btoa(String.fromCharCode(...chunk)),
        next: offset + chunk.length,
        eof: offset + chunk.length === content.length,
      },
    };
  });
  expect(
    await executeShellCommand({
      command: '/usr/bin/loki',
      args: ['report', 'masked', '{}'],
    }),
  ).toEqual({ code: 0, stdout, stderr: 'detail' });
  expect(mocks.callUbus).toHaveBeenLastCalledWith(
    expect.objectContaining({
      params: { id: ID, part: 'release', offset: 0 },
    }),
  );
});

it('rejects a nonadvancing result cursor and still releases server output', async () => {
  commandReply = { code: 0, stdout: '', stderr: '', result_id: ID };
  mocks.callUbus.mockImplementation((options) =>
    options.params.part === 'stdout'
      ? {
          success: true,
          data: { success: true, data: 'YQ==', next: 0, eof: false },
        }
      : protocol(options),
  );
  const reply = await executeShellCommand({
    command: '/usr/bin/loki',
    args: ['show_config', 'raw'],
  });
  expect(reply.code).toBe(1);
  expect(reply.stderr).toBe('Invalid RPC result');
  expect(mocks.callUbus).toHaveBeenLastCalledWith(
    expect.objectContaining({
      method: 'rpc_write_result',
      params: { id: ID, part: 'release', offset: 0 },
    }),
  );
});
