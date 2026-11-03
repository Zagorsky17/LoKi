import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const backend = vi.hoisted(() => ({ call: vi.fn() }));
vi.mock('../src/helpers/callUbus', () => ({ callUbus: backend.call }));

let writable = false;
let sequence = 0;
let mutations: string[];
let snapshots = 0;
let logs = 0;
let jobs: Map<string, { argv: string[]; response?: unknown }>;
let direct: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  writable = false;
  sequence = snapshots = logs = 0;
  mutations = [];
  jobs = new Map();
  vi.stubGlobal('L', { hasViewPermission: () => writable });
  vi.stubGlobal('window', {
    location: { hostname: 'router.example', protocol: 'http:' },
  });
  vi.stubGlobal('fs', {
    exec: vi.fn(() => {
      throw new Error('raw executor must not be called');
    }),
  });
  direct = vi.fn(async (_url: string, init?: RequestInit) => ({
    status: init?.method === 'DELETE' ? 204 : 401,
    text: async () => '',
  }));
  vi.stubGlobal('fetch', direct);
  backend.call
    .mockReset()
    .mockImplementation(
      ({
        method,
        params = {},
      }: {
        method: string;
        params?: Record<string, unknown>;
      }) => {
        if (method === 'config' || method === 'config_private') {
          return {
            success: true,
            data: { sections: [{ '.type': 'settings' }] },
          };
        }
        if (method === 'log_text') {
          logs++;
          if (logs === 1)
            return {
              success: true,
              data: { cursor: 4, text: 'first\nстрока' },
            };
          if (logs === 2)
            return { success: true, data: { cursor: 4, unchanged: true } };
          if (logs === 3)
            return {
              success: false,
              message: 'rpcd restarted',
              unavailable: true,
            };
          return { success: true, data: { cursor: 5, text: 'after restart' } };
        }
        if (method.endsWith('_prepare')) {
          if (method === 'rpc_write_prepare' && !writable) {
            return {
              success: false,
              message: 'permission denied',
              unavailable: false,
            };
          }
          if (jobs.size >= 3)
            return {
              success: true,
              data: { success: false, message: 'session command limit busy' },
            };
          const id = (++sequence).toString(16).padStart(64, '0');
          jobs.set(id, { argv: params.argv as string[] });
          return { success: true, data: { success: true, id } };
        }
        if (method === 'rpc_read' || method === 'rpc_write') {
          const id = params.request_id as string;
          const job = jobs.get(id)!;
          let stdout: string;
          if (job.argv[0] === 'check_logs') stdout = 'fallback\nстрока';
          else if (job.argv[1] === 'DELETE') {
            mutations.push(job.argv[2]);
            stdout = JSON.stringify({ status: 204, body: '' });
          } else {
            stdout = JSON.stringify({
              status: 200,
              body: JSON.stringify({
                connections: [{ id: `connection-${++snapshots}` }],
              }),
            });
          }
          job.response = { code: 0, stdout, stderr: '' };
          return { success: true, data: { pending: true, result_id: id } };
        }
        const job = jobs.get(params.id as string);
        if (params.part === 'release') {
          jobs.delete(params.id as string);
          return { success: true, data: { success: true } };
        }
        return {
          success: true,
          data: { success: true, pending: false, response: job?.response },
        };
      },
    );
});

afterEach(() => vi.unstubAllGlobals());

it('keeps reader Monitoring snapshots updating through prepared RPC without a browser bearer or direct HTTP', async () => {
  const { getClashApiConnections } = await import(
    '../src/forkop/methods/custom/clashApi'
  );
  expect(await getClashApiConnections()).toEqual({
    success: true,
    data: { connections: [{ id: 'connection-1' }] },
  });
  expect(await getClashApiConnections()).toEqual({
    success: true,
    data: { connections: [{ id: 'connection-2' }] },
  });
  expect(backend.call).toHaveBeenCalledWith(
    expect.objectContaining({
      method: 'rpc_read_prepare',
      params: { argv: ['clash_api', 'GET', '/connections', ''] },
    }),
  );
  expect(direct).not.toHaveBeenCalled();
  expect(fs.exec).not.toHaveBeenCalled();
});

it('enforces write RPC for close-one and close-all even when a direct controller would accept DELETE', async () => {
  const { closeClashApiConnection, closeAllClashApiConnections } = await import(
    '../src/forkop/methods/custom/clashApi'
  );
  expect((await closeClashApiConnection('connection-1')).success).toBe(false);
  expect((await closeAllClashApiConnections()).success).toBe(false);
  expect(mutations).toEqual([]);
  writable = true;
  expect((await closeClashApiConnection('connection-1')).success).toBe(true);
  expect((await closeAllClashApiConnections()).success).toBe(true);
  expect(mutations).toEqual(['/connections/connection-1', '/connections']);
  expect(direct).not.toHaveBeenCalled();
  expect(fs.exec).not.toHaveBeenCalled();
});

it('keeps Logs cursor polling and real prepared-read fallback working across a resident restart', async () => {
  const { ForkopShellMethods } = await import('../src/forkop/methods/shell');
  expect(await ForkopShellMethods.checkLogs()).toEqual({
    success: true,
    data: 'first\nстрока',
  });
  expect(await ForkopShellMethods.checkLogs()).toEqual({
    success: true,
    data: 'first\nстрока',
  });
  expect(await ForkopShellMethods.checkLogs()).toEqual({
    success: true,
    data: 'fallback\nстрока',
  });
  expect(await ForkopShellMethods.checkLogs()).toEqual({
    success: true,
    data: 'after restart',
  });
  expect(
    backend.call.mock.calls
      .filter(([call]) => call.method === 'log_text')
      .map(([call]) => call.params ?? {}),
  ).toEqual([{}, { cursor: 4 }, { cursor: 4 }, {}]);
  expect(backend.call).toHaveBeenCalledWith(
    expect.objectContaining({
      method: 'rpc_read_prepare',
      params: { argv: ['check_logs'] },
    }),
  );
  expect(
    backend.call.mock.calls.some(([call]) =>
      call.method.startsWith('rpc_write'),
    ),
  ).toBe(false);
  expect(fs.exec).not.toHaveBeenCalled();
});

it('closes every matching connection while a Monitoring read holds the third session slot', async () => {
  writable = true;
  jobs.set('inflight-monitoring-read', {
    argv: ['clash_api', 'GET', '/connections', ''],
  });
  const { closeClashApiConnection } = await import(
    '../src/forkop/methods/custom/clashApi'
  );
  const { closeConnections } = await import(
    '../src/forkop/tabs/monitoring/closeConnections'
  );
  const ids = Array.from({ length: 10 }, (_, i) => `connection-${i}`);
  expect(await closeConnections(ids, closeClashApiConnection)).toEqual({
    closed: ids,
    failed: [],
  });
  expect(mutations).toEqual(ids.map((id) => `/connections/${id}`));
  expect(jobs.size).toBe(1);
  expect(direct).not.toHaveBeenCalled();
});
