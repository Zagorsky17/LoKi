// Modified for LoKi on 2026-11-01: keep browser traffic observations informational.
import type {
  IDiagnosticsChecksItem,
  IDiagnosticsChecksStoreItem,
  StoreType,
} from '../../services';
import type { Forkop } from '../../types';
import { formatDuration } from '../../helpers/formatDuration';
import { formatMegabytes } from './checks/present';

const MARKS: Record<
  IDiagnosticsChecksStoreItem['state'] | IDiagnosticsChecksItem['state'],
  string
> = {
  info: 'ℹ',
  success: '✓',
  warning: '!',
  error: '✗',
  skipped: '–',
  loading: '…',
};

// The checks as the page shows them: a group per line, its findings under it.
export function checksText(checks: IDiagnosticsChecksStoreItem[]) {
  const lines: string[] = [];

  for (const check of [...checks].sort((a, b) => a.order - b.order)) {
    lines.push(`${MARKS[check.state]} ${check.title} — ${check.description}`);
    for (const item of check.items) {
      lines.push(
        `    ${MARKS[item.state]} ${item.key}${item.value ? `: ${item.value}` : ''}`,
      );
    }
  }

  return `${lines.join('\n')}\n`;
}

function pad(value: number) {
  return String(value).padStart(2, '0');
}

function timestamp(date: Date) {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function section(title: string, body: string) {
  const text = body.trim();
  return `== ${title} ==\n${text ? `${text}\n` : `${_('empty')}\n`}`;
}

export interface ReportInput {
  visibility: 'masked' | 'raw';
  generatedAt: Date;
  systemInfo: StoreType['diagnosticsSystemInfo'];
  luciVersion: string;
  service?: Forkop.ServiceCheckResult;
}

// The router masks the checks like the rest of the report.
export function reportText(
  input: ReportInput,
  attachments: Forkop.ReportAttachments,
) {
  if (attachments.visibility !== input.visibility) {
    throw new Error('Unexpected report visibility');
  }
  const { systemInfo, service } = input;
  const versions = [`Forkop ${systemInfo.forkop_version}`];
  if (input.luciVersion && input.luciVersion !== systemInfo.forkop_version) {
    versions.push(`LuCI ${input.luciVersion}`);
  }
  versions.push(
    `sing-box-forkop ${systemInfo.sing_box_version}` +
      (systemInfo.sing_box_variant ? ` (${systemInfo.sing_box_variant})` : ''),
  );

  const system = [
    versions.join(' · '),
    `${systemInfo.openwrt_version} · ${systemInfo.device_model}`,
  ];
  if (service) {
    system.push(
      `${_('Router up for %s').format(formatDuration(service.router_uptime))} · ${_(
        'Memory: %s of %s free',
      ).format(
        formatMegabytes(service.memory.available_kb),
        formatMegabytes(service.memory.total_kb),
      )}`,
    );
  }

  return [
    attachments.visibility === 'raw'
      ? _('UNMASKED REPORT: contains keys and passwords. Do not share.')
      : _('MASKED REPORT: review before sharing.'),
    `${_('Forkop diagnostic report')} · ${timestamp(input.generatedAt)}\n`,
    section(_('System'), system.join('\n')),
    section(_('Checks'), attachments.checks),
    section(_('Log'), attachments.log),
    section(_('Forkop configuration'), attachments.forkop_config),
    section('nftables', attachments.nftables),
    section(_('Routing rules'), attachments.ip_rules),
  ].join('\n');
}
