import * as RadixTooltip from '@radix-ui/react-tooltip';
import { QueryClientProvider } from '@tanstack/react-query';
import * as React from 'react';

import ErrorBoundary from '~/app/ErrorBoundary';
import { Toaster } from '~/components/shared/Toast';
import { queryClient } from '~/misc/query';
import { actions, initialState } from '~/store';
import StateProvider from '~/store/StateProvider';

type Props = {
  children: React.ReactNode;
};

export function AppProviders({ children }: Props) {
  return (
    <ErrorBoundary>
      <StateProvider initialState={initialState} actions={actions}>
        <QueryClientProvider client={queryClient}>
          <RadixTooltip.Provider delayDuration={0}>
            {children}
            <Toaster />
          </RadixTooltip.Provider>
        </QueryClientProvider>
      </StateProvider>
    </ErrorBoundary>
  );
}
