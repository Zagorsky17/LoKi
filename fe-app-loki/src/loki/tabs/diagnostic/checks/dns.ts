import { LokiShellMethods } from '../../../methods';
import type { IDiagnosticsChecksItem } from '../../../services';
import type { Loki } from '../../../types';
import {
  CheckOutcome,
  finding,
  formatMs,
  outcome,
  unanswered,
} from './present';

function mainItem(main: Loki.DnsCheckResult['main']) {
  const key = _('Main DNS');

  if (main.answered) {
    return finding('success', key, `${main.servers} · ${formatMs(main.ms)}`);
  }

  return finding(
    'error',
    key,
    main.status
      ? _('%s answers with %s').format(main.servers, main.status)
      : _('%s does not answer').format(main.servers),
  );
}

function bootstrapItem(
  bootstrap: NonNullable<Loki.DnsCheckResult['bootstrap']>,
) {
  const key = _('Bootstrap DNS');

  if (bootstrap.answered) {
    return finding(
      'success',
      key,
      `${bootstrap.servers} · ${formatMs(bootstrap.ms)}`,
    );
  }

  return finding(
    'error',
    key,
    _('%s cannot find %s').format(bootstrap.servers, bootstrap.host),
  );
}

function localItem(local: Loki.DnsCheckResult['local']) {
  const key = _('Local DNS');

  return local.answered
    ? finding('success', key, `dnsmasq · ${formatMs(local.ms)}`)
    : finding('error', key, _('dnsmasq does not answer'));
}

export function presentDns(
  data: Loki.DnsCheckResult,
): IDiagnosticsChecksItem[] {
  return [
    mainItem(data.main),
    ...(data.bootstrap ? [bootstrapItem(data.bootstrap)] : []),
    localItem(data.local),
  ];
}

export async function runDnsCheck(): Promise<CheckOutcome> {
  const response = await LokiShellMethods.checkDns();

  return response.success ? outcome(presentDns(response.data)) : unanswered();
}
