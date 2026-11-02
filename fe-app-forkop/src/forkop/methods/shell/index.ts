import { callBaseMethod } from './callBaseMethod';
import { Forkop } from '../../types';
import { callUbus } from '../../../helpers/callUbus';
import { executeShellCommand } from '../../../helpers/executeShellCommand';

const UI_ACTION_RPC_TIMEOUT_MS = 15000;
const GET_UI_STATE_RPC_TIMEOUT_MS = 3000;
// Covers only the state service still computing its first answer.
const SYSTEM_INFO_UBUS_TIMEOUT_MS = 5000;
const LOG_TEXT_UBUS_TIMEOUT_MS = 5000;
// The router-side Clash transport gives an update a minute; LuCI aborts an RPC after twenty
// seconds unless the timeout is raised.
const CLASH_API_TRANSPORT_TIMEOUT_MS = 65000;
// A check on a slow router takes far longer than an ordinary RPC.
const DIAGNOSTIC_CHECK_RPC_TIMEOUT_MS = 3 * 60 * 1000;

let checkLogsRequest: Promise<Forkop.MethodResponse<string>> | null = null;
let servedLog: { cursor: number; text: string } | null = null;

type LogTextReply = { cursor?: number; unchanged?: boolean; text?: string };

// The state service reads the log again only once a line arrived past the cursor it handed out;
// the CLI answers when the service does not run. A log with no Forkop line yet is empty, not a
// failed read.
async function readLogs(): Promise<Forkop.MethodResponse<string>> {
  const served = await callUbus<LogTextReply>({
    object: 'forkop',
    method: 'log_text',
    params: servedLog ? { cursor: servedLog.cursor } : {},
    timeoutMs: LOG_TEXT_UBUS_TIMEOUT_MS,
  });
  const reply = served.success ? served.data : null;
  if (typeof reply?.cursor === 'number') {
    const text = reply.unchanged ? servedLog?.text : reply.text;
    if (typeof text === 'string') {
      servedLog = { cursor: reply.cursor, text };
      return { success: true, data: text };
    }
  }

  servedLog = null;
  const response = await executeShellCommand({
    command: '/usr/bin/forkop',
    args: [Forkop.AvailableMethods.CHECK_LOGS],
    timeout: 15000,
  });
  return response.code
    ? { success: false, error: response.stderr || response.stdout || '' }
    : { success: true, data: response.stdout };
}

function checkLogs() {
  if (!checkLogsRequest) {
    checkLogsRequest = readLogs().finally(() => {
      checkLogsRequest = null;
    });
  }

  return checkLogsRequest;
}

function parseJsonObjectOutput<T>(output: string): T | null {
  if (!output) {
    return null;
  }

  try {
    return JSON.parse(output) as T;
  } catch (_error) {
    const jsonMatch = output.match(/(\{[\s\S]*\})\s*$/);

    if (!jsonMatch) {
      return null;
    }

    try {
      return JSON.parse(jsonMatch[1]) as T;
    } catch (_jsonError) {
      return null;
    }
  }
}

function parseUiActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Forkop.UiActionStartResult>(response.stdout);
}

function uiActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: { message?: string } | null,
  fallback: string = _('Failed to execute'),
) {
  return {
    success: false,
    error: parsedResponse?.message || response.stderr || fallback,
  } as Forkop.MethodFailureResponse;
}

function diagnosticCheck<T>(
  method: Forkop.AvailableMethods,
  args: string[] = [],
) {
  return callBaseMethod<T>(method, args, '/usr/bin/forkop', {
    timeout: DIAGNOSTIC_CHECK_RPC_TIMEOUT_MS,
  });
}

export const ForkopShellMethods = {
  checkService: async () =>
    diagnosticCheck<Forkop.ServiceCheckResult>(
      Forkop.AvailableMethods.CHECK_SERVICE,
    ),
  checkDns: async () =>
    diagnosticCheck<Forkop.DnsCheckResult>(Forkop.AvailableMethods.CHECK_DNS),
  checkTraffic: async () =>
    diagnosticCheck<Forkop.TrafficCheckResult>(
      Forkop.AvailableMethods.CHECK_TRAFFIC,
    ),
  // The router masks the checks by the same rules as the rest of the report.
  report: async (masked: boolean, checks: string) =>
    diagnosticCheck<Forkop.ReportAttachments>(Forkop.AvailableMethods.REPORT, [
      masked ? 'masked' : 'raw',
      checks,
    ]),
  clashApi: async (method: string, path: string, body = '') =>
    callBaseMethod<Forkop.ClashApiResponse>(
      Forkop.AvailableMethods.CLASH_API,
      [method, path, body],
      '/usr/bin/forkop',
      {
        timeout:
          method.toUpperCase() === 'GET' && !/\/(delay|exit)\?/.test(path)
            ? 10000
            : CLASH_API_TRANSPORT_TIMEOUT_MS,
      },
    ),
  clashSummary: async () =>
    callBaseMethod<Forkop.ClashApiResponse>(
      Forkop.AvailableMethods.CLASH_SUMMARY,
      [],
      '/usr/bin/forkop',
      { timeout: 10000 },
    ),
  // Through the CLI: init script commands wait on procd's per-service lock.
  enable: async () => callBaseMethod<unknown>(Forkop.AvailableMethods.ENABLE),
  disable: async () => callBaseMethod<unknown>(Forkop.AvailableMethods.DISABLE),
  checkLogs,
  // The state service holds the versions until the installed packages change; the CLI answers
  // when it is not running.
  getSystemInfo: async () => {
    const served = await callUbus<{
      available?: boolean;
      system_info?: Forkop.GetSystemInfo;
    }>({
      object: 'forkop',
      method: 'system_info',
      timeoutMs: SYSTEM_INFO_UBUS_TIMEOUT_MS,
    });

    if (served.success && served.data.available && served.data.system_info) {
      return { success: true as const, data: served.data.system_info };
    }

    return callBaseMethod<Forkop.GetSystemInfo>(
      Forkop.AvailableMethods.GET_SYSTEM_INFO,
    );
  },
  // Runs the core itself, so only a page the state service cannot answer asks.
  getCoreFeatures: async () =>
    callBaseMethod<Forkop.CoreFeatures>(
      Forkop.AvailableMethods.GET_CORE_FEATURES,
    ),
  getUiState: async () =>
    callBaseMethod<Forkop.UiState>(
      Forkop.AvailableMethods.GET_UI_STATE,
      [],
      '/usr/bin/forkop',
      { timeout: GET_UI_STATE_RPC_TIMEOUT_MS },
    ),
  serviceActionStart: async (action: Forkop.ServiceAction) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.SERVICE_ACTION_ASYNC, action],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Service action failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.UiActionStartResult>;
  },
  uiActionAck: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.UI_ACTION_ACK, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse?.success) {
      return uiActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.UiActionStartResult>;
  },
};
