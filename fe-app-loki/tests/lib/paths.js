import path from 'path';

const FRONTEND = path.resolve(import.meta.dirname, '..', '..');
export const ROOT = path.resolve(FRONTEND, '..');
export const SRC = path.join(FRONTEND, 'src');
export const VIEW_DIR = path.join(
  ROOT,
  'luci-app-loki/htdocs/luci-static/resources/view/loki',
);
