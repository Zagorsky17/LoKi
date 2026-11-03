import { callUbus } from '../../../helpers/callUbus';
import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { Forkop } from '../../types';

// The object the run's own process publishes for its lifetime; service/installer.uc names it.
export const INSTALLER_OBJECT = 'forkop.installer';
export const INSTALLER_ACTIONS: readonly Forkop.InstallerAction[] = [
  'check',
  'update',
  'variant',
  'uninstall',
];

const START_TIMEOUT_MS = 15000;
const STATUS_TIMEOUT_MS = 10000;
const READ_TIMEOUT_MS = 5000;

export interface InstallerRead {
  snapshot: Forkop.InstallerSnapshot | null;
  // the run's process has ended or never published: the CLI knows the rest
  gone: boolean;
}

function parseJson<T>(text: string): T | null {
  try {
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}

export const installerApi = {
  async start(
    action: Forkop.InstallerAction,
    variant: string,
    purge: boolean,
    lang: string,
  ): Promise<Forkop.InstallerStartResult> {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [
        Forkop.AvailableMethods.INSTALLER_START,
        action,
        variant,
        purge ? '1' : '0',
        lang,
      ],
      timeout: START_TIMEOUT_MS,
    });
    const reply = parseJson<
      Partial<Forkop.InstallerStartResult> & {
        success?: boolean;
        message?: string;
      }
    >(response.stdout);
    if (!reply?.success || !reply.id) {
      throw new Error(
        reply?.message || response.stderr || _('Failed to execute'),
      );
    }
    return { id: reply.id, started: Boolean(reply.started) };
  },

  // From the files the run leaves, through the CLI: for a page that has just opened, and for a
  // run whose process is gone.
  async status(offset: number): Promise<Forkop.InstallerSnapshot> {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.INSTALLER_STATUS, String(offset)],
      timeout: STATUS_TIMEOUT_MS,
    });
    const snapshot = parseJson<Forkop.InstallerSnapshot>(response.stdout);
    if (
      (response.code ?? 0) !== 0 ||
      !snapshot ||
      typeof snapshot.id !== 'string'
    ) {
      throw new Error(response.stderr || _('Failed to execute'));
    }
    return snapshot;
  },

  async log(): Promise<string> {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.INSTALLER_LOG],
      timeout: STATUS_TIMEOUT_MS,
    });
    if ((response.code ?? 0) !== 0) {
      throw new Error(response.stderr || _('Failed to execute'));
    }
    return response.stdout;
  },

  async read(id: string, offset: number): Promise<InstallerRead> {
    const reply = await callUbus<Forkop.InstallerSnapshot>({
      object: INSTALLER_OBJECT,
      method: 'read',
      params: { id, offset },
      timeoutMs: READ_TIMEOUT_MS,
      retryUnavailable: false,
    });
    if (reply.success) {
      return { snapshot: reply.data, gone: false };
    }
    if (reply.unavailable) {
      return { snapshot: null, gone: true };
    }
    throw new Error(reply.message);
  },

  async input(id: string, data: string): Promise<boolean> {
    const reply = await callUbus<{ accepted?: boolean }>({
      object: INSTALLER_OBJECT,
      method: 'input',
      params: { id, data },
      timeoutMs: READ_TIMEOUT_MS,
      retryUnavailable: false,
    });
    return reply.success && Boolean(reply.data.accepted);
  },

  async stop(id: string): Promise<boolean> {
    const reply = await callUbus<{ accepted?: boolean }>({
      object: INSTALLER_OBJECT,
      method: 'stop',
      params: { id },
      timeoutMs: READ_TIMEOUT_MS,
      retryUnavailable: false,
    });
    return reply.success && Boolean(reply.data.accepted);
  },
};

export type InstallerApi = typeof installerApi;
