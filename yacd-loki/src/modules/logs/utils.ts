export const LOG_TYPES: Record<string, string> = {
  debug: 'debug',
  info: 'info',
  warning: 'warn',
  error: 'error',
};

/** 距底部多少像素以内算「贴着底」，自动跟随新日志 */
export const LOGS_SCROLL_BOTTOM_THRESHOLD = 50;
