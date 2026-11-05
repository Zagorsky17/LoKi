import react from '@vitejs/plugin-react';
import * as path from 'path';
import { defineConfig } from 'vite';

import pkg from './package.json' with { type: 'json' };

// https://vitejs.dev/config/
export default defineConfig(({ mode }) => ({
  define: {
    __VERSION__: JSON.stringify(pkg.version),
  },
  base: './',
  server: {
    host: '127.0.0.1',
    port: 3000,
  },
  resolve: {
    alias: {
      '~': path.resolve(import.meta.dirname, './src'),
    },
  },
  publicDir: 'assets',
  build: {
    // sourcemap: true,
    // the default value is 'dist'
    // which make more sense
    // but change this may break other people's tools
    outDir: 'public',
  },
  plugins: [react()],
}));
