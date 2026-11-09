import { afterEach, describe, expect, it, vi } from 'vitest';

import { logger } from '../logger.service';

afterEach(() => {
  vi.restoreAllMocks();
});

describe('logger', () => {
  it('hands the console what it was given, at the level it was said at', () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    const failure = new Error('refused');

    logger.error('[TABS]', 'failed', failure);

    expect(error).toHaveBeenCalledWith('[ERROR]', '[TABS]', 'failed', failure);
  });

  it('says the debug lines at the debug level', () => {
    const debug = vi.spyOn(console, 'debug').mockImplementation(() => {});

    logger.debug('[SHELL]', 'took 1 ms');

    expect(debug).toHaveBeenCalledWith('[DEBUG]', '[SHELL]', 'took 1 ms');
  });
});
