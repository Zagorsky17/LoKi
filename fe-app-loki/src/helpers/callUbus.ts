import { alignLuciRpcTimeout } from './alignLuciRpcTimeout';
import { withTimeout } from './withTimeout';

type UbusCallResult<T> =
  | { success: true; data: T }
  | { success: false; message: string; unavailable: boolean };

// LuCI hands main.ts its rpc module as a parameter of the view wrapper, not as a global; resolving
// it lazily keeps this module importable from tests.
function rpcModule() {
  const candidate = typeof rpc === 'undefined' ? undefined : rpc;
  return candidate as unknown as
    | {
        declare: (options: {
          object: string;
          method: string;
          params?: string[];
          nobatch?: boolean;
        }) => (...args: unknown[]) => Promise<unknown>;
      }
    | undefined;
}

// A missing object or a denied ACL comes back as a status code; both mean this route is unavailable.
const UNAVAILABLE_STATUS = new Set([
  2, // invalid argument
  4, // method not found
  5, // not found
  6, // permission denied
]);

function isUnavailable(error: unknown) {
  const status = (error as { ubus_rpc_status?: unknown })?.ubus_rpc_status;
  if (typeof status === 'number') {
    return UNAVAILABLE_STATUS.has(status);
  }

  const message = error instanceof Error ? error.message : String(error ?? '');
  return /not found|permission denied|Object not found/i.test(message);
}

// A service restarted by an upgrade or by procd is missing for a second or two, so a call that
// finds nothing is retried briefly before the caller falls back.
const UNAVAILABLE_RETRIES = 2;
const UNAVAILABLE_RETRY_MS = 700;

function wait(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// LuCI batches the calls of one animation frame into one HTTP request, which uhttpd answers only
// when the last call is done, so a parked call is sent on its own.
export async function callUbus<T>(options: {
  object: string;
  method: string;
  params?: Record<string, unknown>;
  timeoutMs: number;
  retryUnavailable?: boolean;
  nobatch?: boolean;
}): Promise<UbusCallResult<T>> {
  const attempts =
    options.retryUnavailable === false ? 1 : UNAVAILABLE_RETRIES + 1;
  let last = await callUbusOnce<T>(options);

  for (
    let attempt = 1;
    attempt < attempts && !last.success && last.unavailable;
    attempt++
  ) {
    await wait(UNAVAILABLE_RETRY_MS);
    last = await callUbusOnce<T>(options);
  }

  return last;
}

async function callUbusOnce<T>({
  object,
  method,
  params = {},
  timeoutMs,
  nobatch,
}: {
  object: string;
  method: string;
  params?: Record<string, unknown>;
  timeoutMs: number;
  nobatch?: boolean;
}): Promise<UbusCallResult<T>> {
  const rpc = rpcModule();
  if (!rpc) {
    return { success: false, message: 'rpc unavailable', unavailable: true };
  }

  alignLuciRpcTimeout(timeoutMs);

  try {
    const names = Object.keys(params);
    const request = rpc.declare({ object, method, params: names, nobatch });
    const call = request(...names.map((name) => params[name])) as Promise<T>;
    const data = await withTimeout(call, timeoutMs, `${object}.${method}`);

    if (data === null || data === undefined) {
      return { success: false, message: 'empty reply', unavailable: false };
    }

    return { success: true, data };
  } catch (error) {
    return {
      success: false,
      message: error instanceof Error ? error.message : String(error),
      unavailable: isUnavailable(error),
    };
  }
}
