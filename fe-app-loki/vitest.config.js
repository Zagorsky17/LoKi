import { defineConfig } from 'vitest/config';

export default defineConfig({
    test: {
        globals: true,
        environment: 'node',
        // A test that drives a failure on purpose makes the page log it; that
        // output is shown for a test that fails and kept out of the way otherwise.
        silent: 'passed-only',
        setupFiles: ['./tests/setup/global-mocks.ts'],
    },
});
