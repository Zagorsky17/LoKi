// LuCI aborts every RPC after L.env.rpctimeout seconds (20 by default), capping longer timeouts, so
// the transport ceiling is raised to cover the requested timeout.
const LUCI_RPC_TIMEOUT_DEFAULT_SECONDS = 20;
const LUCI_RPC_TIMEOUT_HEADROOM_SECONDS = 5;

export function alignLuciRpcTimeout(timeoutMs: number) {
  const env = typeof L === 'undefined' ? undefined : L?.env;

  if (!env || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return;
  }

  const required =
    Math.ceil(timeoutMs / 1000) + LUCI_RPC_TIMEOUT_HEADROOM_SECONDS;
  const current =
    typeof env.rpctimeout === 'number' && Number.isFinite(env.rpctimeout)
      ? env.rpctimeout
      : LUCI_RPC_TIMEOUT_DEFAULT_SECONDS;

  if (current < required) {
    env.rpctimeout = required;
  }
}
