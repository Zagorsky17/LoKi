import '~/styles/main.scss';
import './misc/i18n';

import React from 'react';
import { createRoot } from 'react-dom/client';

import App from './App';
import { registerAppBootstrap } from './app/bootstrap';

const rootEl = document.getElementById('app');
if (!rootEl) {
  throw new Error('Cannot find #app root element');
}

const root = createRoot(rootEl);

root.render(<App />);

registerAppBootstrap(rootEl);
