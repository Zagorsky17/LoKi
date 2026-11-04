import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { Loki } from '../../types';

interface CallBaseMethodOptions {
  timeout?: number | null;
}

export async function callBaseMethod<T>(
  method: Loki.AvailableMethods,
  args: string[] = [],
  command: string = '/usr/bin/loki',
  options: CallBaseMethodOptions = {},
): Promise<Loki.MethodResponse<T>> {
  try {
    const response = await executeShellCommand({
      command,
      args: [method as string, ...args],
      timeout: options.timeout === undefined ? 15000 : options.timeout,
    });
    const exitCode = response.code ?? 0;

    if (exitCode !== 0) {
      return {
        success: false,
        error: response.stderr || response.stdout || '',
      };
    }

    if (response.stdout) {
      try {
        return {
          success: true,
          data: JSON.parse(response.stdout) as T,
        };
      } catch (_e) {
        return {
          success: true,
          data: response.stdout as T,
        };
      }
    }

    return {
      success: false,
      error: response.stderr || '',
    };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : '',
    };
  }
}
