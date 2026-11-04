import { COMMAND_TIMEOUT } from '../constants';
import { callUbus } from './callUbus';

interface ExecuteShellCommandParams {
  command: string;
  args: string[];
  timeout?: number | null;
}

interface ExecuteShellCommandResponse {
  stdout: string;
  stderr: string;
  code?: number;
  result_id?: string;
}

const MAX_RESULT_BYTES = 4 * 1024 * 1024;
const RESULT_CHUNK_BYTES = 32768;

async function collectResult(method: string, id: string) {
  if (!/^[a-f0-9]{64}$/.test(id)) throw new Error('Invalid RPC result');
  let total = 0;
  async function read(part: 'stdout' | 'stderr') {
    const decoder = new TextDecoder('utf-8', { fatal: true });
    let offset = 0;
    let text = '';
    for (
      let count = 0;
      count <= MAX_RESULT_BYTES / RESULT_CHUNK_BYTES;
      count++
    ) {
      const response = await callUbus<{
        success: boolean;
        data: string;
        next: number;
        eof: boolean;
      }>({
        object: 'loki',
        method: `${method}_result`,
        params: { id, part, offset },
        timeoutMs: 15000,
        retryUnavailable: false,
        nobatch: true,
      });
      if (
        !response.success ||
        response.data?.success !== true ||
        typeof response.data.data !== 'string' ||
        response.data.data.length > 43692 ||
        typeof response.data.eof !== 'boolean'
      )
        throw new Error('Invalid RPC result');
      const bytes = Uint8Array.from(atob(response.data.data), (char) =>
        char.charCodeAt(0),
      );
      total += bytes.length;
      if (
        bytes.length > RESULT_CHUNK_BYTES ||
        total > MAX_RESULT_BYTES ||
        response.data.next !== offset + bytes.length ||
        (!response.data.eof && !bytes.length)
      ) {
        throw new Error('Invalid RPC result');
      }
      text += decoder.decode(bytes, { stream: true });
      offset = response.data.next;
      if (response.data.eof) return text + decoder.decode();
    }
    throw new Error('Invalid RPC result');
  }
  return { stdout: await read('stdout'), stderr: await read('stderr') };
}

async function waitResult(method: string, id: string, deadline: number) {
  while (Date.now() < deadline) {
    const reply = await callUbus<{
      success: boolean;
      pending: boolean;
      response?: ExecuteShellCommandResponse;
      message?: string;
    }>({
      object: 'loki',
      method: `${method}_result`,
      params: { id, part: 'status', offset: 0 },
      timeoutMs: Math.min(15000, Math.max(1, deadline - Date.now())),
      retryUnavailable: false,
      nobatch: true,
    });
    if (!reply.success) throw new Error(reply.message);
    if (
      reply.data?.success !== true ||
      typeof reply.data.pending !== 'boolean'
    ) {
      throw new Error(
        reply.data?.message ||
          'The RPC outcome is unavailable; check operation status',
      );
    }
    if (!reply.data.pending) return reply.data.response;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('The RPC outcome is unknown; check operation status');
}

// The server rechecks the operation and the session; this only selects the ACL method.
export function readOnlyLokiArgs(args: string[]): boolean {
  if (
    args.some(
      (arg) =>
        arg.length > 65536 ||
        Array.from(arg).some(
          (char) => char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127,
        ),
    )
  ) {
    return false;
  }
  if (
    args.length === 1 &&
    [
      'check_service',
      'check_dns',
      'check_traffic',
      'check_logs',
      'clash_summary',
      'get_status',
      'get_system_info',
      'get_ui_state',
      'get_core_features',
      'show_version',
      'installer_log',
    ].includes(args[0])
  ) {
    return true;
  }
  switch (args[0]) {
    case 'show_config':
    case 'show_sing_box_config':
      return args.length === 2 && args[1] === 'masked';
    case 'report':
      return args.length === 3 && args[1] === 'masked';
    case 'installer_status':
      return args.length === 2 && /^[0-9]{1,9}$/.test(args[1]);
    case 'installer_start':
      return (
        args.length === 5 &&
        args[1] === 'check' &&
        args[2] === '' &&
        args[3] === '0' &&
        ['ru', 'en'].includes(args[4])
      );
    case 'clash_api':
      return (
        args.length === 4 &&
        args[1] === 'GET' &&
        args[3] === '' &&
        ['/proxies', '/providers/proxies', '/connections'].includes(args[2])
      );
    default:
      return false;
  }
}

export async function executeShellCommand({
  command,
  args,
  timeout = COMMAND_TIMEOUT,
}: ExecuteShellCommandParams): Promise<ExecuteShellCommandResponse> {
  try {
    if (command === '/usr/bin/loki') {
      const method = readOnlyLokiArgs(args) ? 'rpc_read' : 'rpc_write';
      const deadline = Date.now() + (timeout ?? 180000);
      const prepared = await callUbus<{
        success: boolean;
        id?: string;
        message?: string;
      }>({
        object: 'loki',
        method: `${method}_prepare`,
        params: { argv: args },
        timeoutMs: Math.min(timeout ?? 15000, 15000),
        retryUnavailable: false,
        nobatch: true,
      });
      if (!prepared.success)
        return { code: 1, stdout: '', stderr: prepared.message };
      const id = prepared.data?.id;
      if (
        prepared.data?.success !== true ||
        typeof id !== 'string' ||
        !/^[a-f0-9]{64}$/.test(id)
      ) {
        return {
          code: 1,
          stdout: '',
          stderr:
            prepared.data?.message || 'The RPC request could not be prepared',
        };
      }
      try {
        const result = await callUbus<
          ExecuteShellCommandResponse & { pending?: boolean }
        >({
          object: 'loki',
          method,
          params: { argv: args, request_id: id },
          timeoutMs: Math.min(15000, Math.max(1, deadline - Date.now())),
          retryUnavailable: false,
          nobatch: true,
        });
        // A known prepared id recovers a lost start reply without submitting the write again.
        const response =
          result.success && result.data?.pending !== true
            ? result.data
            : await waitResult(method, id, deadline);
        if (
          !(
            typeof response?.stdout === 'string' &&
            typeof response?.stderr === 'string' &&
            Number.isInteger(response.code) &&
            (response.code ?? -1) >= 0 &&
            (response.code ?? 256) <= 255
          )
        ) {
          return { code: 1, stdout: '', stderr: 'Invalid RPC response' };
        }
        return response.result_id === undefined
          ? response
          : response.result_id === id
            ? {
                code: response.code,
                ...(await collectResult(method, id)),
              }
            : { code: 1, stdout: '', stderr: 'Invalid RPC result' };
      } finally {
        await callUbus({
          object: 'loki',
          method: `${method}_result`,
          params: { id, part: 'release', offset: 0 },
          timeoutMs: 15000,
          retryUnavailable: false,
          nobatch: true,
        });
      }
    }
    return { code: 1, stdout: '', stderr: 'The executable is not allowed' };
  } catch (err) {
    const error = err as Error & { code?: unknown };
    const code = typeof error?.code === 'number' ? error.code : 1;

    return { stdout: '', stderr: error?.message, code };
  }
}
