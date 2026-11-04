import { callUbus } from '../../helpers/callUbus';
import { logger } from './logger.service';
import { LOKI_CALL_TIMEOUT_MS, LOKI_SERVICE_OBJECT } from './lokiWaitTransport';

// The state service reads the log tail once for every tab and hands out lines by cursor, on the
// page's one parked request.
export type LogReply = { cursor?: number; lines?: string[] };

let started = false;
let cursor: number | undefined;
let onLine: (line: string) => void = () => {};

// Undefined until the feed knows where the log stands; until then the wait asks for no lines.
export function getLokiLogCursor() {
  return cursor;
}

// A page taking over from the one LuCI just reloaded continues from its cursor.
export function startLokiLogFeed(
  onNewLog: (line: string) => void,
  resumeFrom = 0,
) {
  if (started) {
    return;
  }
  started = true;
  onLine = onNewLog;

  if (resumeFrom > 0) {
    cursor = resumeFrom;
  }
}

// The feed starts where the log stands: lines already in the buffer are history.
export async function placeLokiLogFeed() {
  if (!started || cursor !== undefined) {
    return;
  }

  const response = await callUbus<LogReply>({
    object: LOKI_SERVICE_OBJECT,
    method: 'logs',
    timeoutMs: LOKI_CALL_TIMEOUT_MS,
  });

  if (response.success) {
    cursor = response.data.cursor ?? 0;
    return;
  }

  logger.info('[LOG_FEED]', 'log position unknown', response.message);
}

// What a state wait sent with the feed's cursor brought back.
export function takeLokiLogLines(reply: LogReply) {
  if (cursor === undefined || typeof reply.cursor !== 'number') {
    return;
  }

  cursor = reply.cursor;
  for (const line of reply.lines || []) {
    try {
      onLine(line);
    } catch (error) {
      logger.error('[LOG_FEED]', 'listener failed', error);
    }
  }
}
