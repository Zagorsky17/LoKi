import { callUbus } from '../../../helpers/callUbus';
import { downloadFile } from '../../../helpers/downloadFile';
import { E } from '../../../helpers/element';
import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { Forkop } from '../../types';

// The one path the rpcd ACL lets the page write, and the one the state service reads.
export const UPLOAD_PATH = '/tmp/forkop-import.conf';
// A LoKi configuration is a few dozen KB; a file far larger was picked by mistake, and /tmp is RAM.
export const MAX_CONFIG_SIZE = 1024 * 1024;
const COMMAND_TIMEOUT_MS = 60000;

export interface ImportCheck {
  success: true;
  from: string;
  to: string;
  warnings: string[];
  changed: boolean;
  unsaved: boolean;
}

export interface ImportRefusal {
  success: false;
  reason: string;
  from?: string;
  to: string;
  min: string;
  detail?: string;
}

type ImportReply = ImportCheck | ImportRefusal | { success: true };

function datePart(date: Date) {
  const pad = (value: number) => `${value}`.padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

// As LuCI names its own backup: the router's host name and the day.
export function exportFileName(hostname: string, date: Date) {
  const host = hostname.trim().replace(/[^A-Za-z0-9._-]+/g, '_');
  return `forkop-${host ? `${host}-` : ''}${datePart(date)}.conf`;
}

async function routerHostname() {
  try {
    await uci.load('system');
    return `${uci.get_first('system', 'system', 'hostname') || ''}`;
  } catch {
    return '';
  }
}

export async function downloadConfig() {
  const response = await executeShellCommand({
    command: '/usr/bin/forkop',
    args: [Forkop.AvailableMethods.SHOW_CONFIG, 'raw'],
    timeout: COMMAND_TIMEOUT_MS,
  });
  if ((response.code ?? 0) !== 0) {
    throw new Error(response.stderr || _('Failed to execute'));
  }
  downloadFile(
    response.stdout,
    exportFileName(await routerHostname(), new Date()),
  );
}

// As an editor on Windows may save it: UCI refuses a byte order mark, and keeps the CR of a CRLF
// inside a multi-line value.
export function configText(text: string) {
  return (text.charCodeAt(0) === 0xfeff ? text.slice(1) : text).replace(
    /\r\n/g,
    '\n',
  );
}

async function uploadConfigText(text: string) {
  const data = new FormData();
  data.append('sessionid', L.env?.sessionid ?? '');
  data.append('filename', UPLOAD_PATH);
  data.append('filedata', new Blob([text]), 'forkop.conf');
  const response = await fetch(`${L.env?.cgi_base ?? '/cgi-bin'}/cgi-upload`, {
    method: 'POST',
    body: data,
  });
  if (!response.ok) {
    const reason = (await response.text().catch(() => '')).trim();
    throw new Error(
      _('Failed to upload the file: %s').format(reason || response.status),
    );
  }
}

// The state service stages into this page's own session: uhttpd adds the caller's session to
// every ubus call. It removes the file once read; this removal is for a call that never got there.
async function runImport<T extends ImportReply>(
  stage: boolean,
  text: string,
): Promise<T> {
  await uploadConfigText(text);
  try {
    const reply = await callUbus<T>({
      object: 'forkop',
      method: 'import_config',
      params: { stage },
      timeoutMs: COMMAND_TIMEOUT_MS,
      nobatch: true,
    });
    if (!reply.success) {
      throw new Error(
        _('Failed to load the configuration: %s').format(reply.message),
      );
    }
    return reply.data;
  } finally {
    await fs.remove(UPLOAD_PATH).catch(() => undefined);
  }
}

export const configImportApi = {
  check: (text: string) => runImport<ImportCheck | ImportRefusal>(false, text),
  stage: (text: string) =>
    runImport<ImportRefusal | { success: true }>(true, text),
};

export function refusalMessage(refusal: ImportRefusal) {
  switch (refusal.reason) {
    case 'file':
      return _('The configuration must be a regular file of at most 1 MiB');
    case 'foreign':
      return _(
        'The file is not a LoKi configuration; importing other applications is not supported',
      );
    case 'schema':
      return _('The file has unsupported or ambiguous LoKi sections');
    case 'unreadable':
      return _('The file is not a UCI configuration');
    case 'missing':
      return _('The file is not a LoKi configuration: it names no version');
    case 'invalid':
      return _(
        'The file is not a LoKi configuration: its version is not a release number',
      );
    case 'newer':
      return _(
        'The configuration is from LoKi %s, newer than this one: update LoKi first',
      ).format(refusal.from);
    case 'below_min':
      return _(
        'The configuration is from LoKi %s, and LoKi loads configurations from %s on',
      ).format(refusal.from, refusal.min);
    case 'unknown':
      return _('No LoKi release wrote configuration version %s').format(
        refusal.from,
      );
    case 'migration':
      return _(
        'The configuration of LoKi %s cannot be brought to %s: %s',
      ).format(refusal.from, refusal.to, refusal.detail);
    default:
      return _('Failed to load the configuration: %s').format(
        refusal.detail || refusal.reason,
      );
  }
}

export function renderImportDialog(
  fileName: string,
  check: ImportCheck,
  onLoad: () => Promise<void>,
) {
  const version =
    check.from === check.to
      ? _('%s holds a configuration of LoKi %s.').format(fileName, check.from)
      : _(
          '%s holds a configuration of LoKi %s, which is brought to %s as an update would bring it.',
        ).format(fileName, check.from, check.to);
  return [
    E('p', {}, version),
    ...(check.warnings.length
      ? [
          E('p', {}, _('What the update changes in it:')),
          E(
            'ul',
            {},
            check.warnings.map((warning) => E('li', {}, warning)),
          ),
        ]
      : []),
    E(
      'p',
      {},
      _(
        'It replaces the current one through unsaved changes, as if you made them by hand. LoKi runs it once you apply them.',
      ),
    ),
    ...(check.unsaved
      ? [E('p', {}, _('Unsaved changes to LoKi made earlier are replaced.'))]
      : []),
    E('div', { class: 'fkp-partial-modal__footer' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          click: () => ui.hideModal(),
        },
        _('Cancel'),
      ),
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button cbi-button-apply',
          click: ui.createHandlerFn({}, onLoad),
        },
        _('Upload'),
      ),
    ]),
  ];
}
