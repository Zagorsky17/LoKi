type LogLevel = 'debug' | 'info' | 'warn' | 'error';

function write(level: LogLevel, args: unknown[]) {
  console[level](`[${level.toUpperCase()}]`, ...args);
}

export const logger = {
  debug: (...args: unknown[]) => write('debug', args),
  info: (...args: unknown[]) => write('info', args),
  warn: (...args: unknown[]) => write('warn', args),
  error: (...args: unknown[]) => write('error', args),
};
