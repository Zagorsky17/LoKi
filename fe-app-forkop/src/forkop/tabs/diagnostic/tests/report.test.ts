// Modified for LoKi on 2026-11-01: report known list overlaps without changing routing.
import { describe, expect, it } from 'vitest';

import { checksText, reportText } from '../report';
import type { IDiagnosticsChecksStoreItem, StoreType } from '../../../services';

const checks: IDiagnosticsChecksStoreItem[] = [
  {
    order: 2,
    code: 'TRAFFIC',
    title: 'Traffic',
    description: 'Checks passed',
    state: 'success',
    items: [
      { state: 'success', key: 'Router', value: 'goes through Forkop' },
      {
        state: 'info',
        key: 'This device',
        value:
          'Browser check did not confirm FakeIP; router results are shown separately',
      },
    ],
  },
  {
    order: 0,
    code: 'SERVICE',
    title: 'Service',
    description: 'Checks passed',
    state: 'success',
    items: [{ state: 'success', key: 'Forkop', value: 'running for 2 h' }],
  },
  {
    order: 3,
    code: 'SECTIONS',
    title: 'Sections',
    description: 'Skipped: Forkop is not running',
    state: 'skipped',
    items: [],
  },
];

describe('the diagnostic report', () => {
  it.each(['masked', 'raw'] as const)(
    'identifies the %s mode in its first line even when checks already contain MASKED',
    (visibility) => {
      const text = reportText(
        {
          visibility,
          generatedAt: new Date(2026, 10, 1),
          systemInfo: {} as StoreType['diagnosticsSystemInfo'],
          luciVersion: '',
        },
        {
          visibility,
          notice:
            visibility === 'raw'
              ? 'UNMASKED REPORT: contains keys and passwords. Do not share.'
              : 'MASKED REPORT: review before sharing.',
          checks: 'DNS: https://dns.test/MASKED',
          log: '',
          forkop_config: '',
          nftables: '',
          ip_rules: '',
        },
      );
      expect(text.split('\n')[0]).toBe(
        visibility === 'raw'
          ? 'UNMASKED REPORT: contains keys and passwords. Do not share.'
          : 'MASKED REPORT: review before sharing.',
      );
    },
  );

  it('rejects a raw or missing response mode when a masked report was requested', () => {
    for (const visibility of ['raw', undefined]) {
      expect(() =>
        reportText(
          {
            visibility: 'masked',
            generatedAt: new Date(),
            systemInfo: {} as StoreType['diagnosticsSystemInfo'],
            luciVersion: '',
          },
          {
            visibility,
            checks: '',
            log: '',
            forkop_config: 'private data',
            nftables: '',
            ip_rules: '',
          } as Parameters<typeof reportText>[1],
        ),
      ).toThrow('Unexpected report visibility');
    }
  });

  it('writes the checks as the page shows them, in their order', () => {
    expect(checksText(checks)).toBe(
      [
        '✓ Service — Checks passed',
        '    ✓ Forkop: running for 2 h',
        '✓ Traffic — Checks passed',
        '    ✓ Router: goes through Forkop',
        '    ℹ This device: Browser check did not confirm FakeIP; router results are shown separately',
        '– Sections — Skipped: Forkop is not running',
        '',
      ].join('\n'),
    );
  });

  it('puts the system first and every attachment under a heading of its own', () => {
    const text = reportText(
      {
        visibility: 'masked',
        generatedAt: new Date(2026, 9, 19, 17, 5),
        systemInfo: {
          forkop_version: '1.0.6',
          sing_box_version: '1.14.4-r1',
          sing_box_variant: 'base',
          openwrt_version: 'OpenWrt 25.12.5 r33051-f5dae5ece4',
          device_model: 'Xiaomi Mi Router AX3000T',
        } as StoreType['diagnosticsSystemInfo'],
        luciVersion: '1.0.6',
        service: {
          running: true,
          uptime: 60,
          last_error: '',
          core: {
            installed: true,
            binary: '1.14.4-r1',
            version: '1.14.4-r1',
            variant: 'base',
            outdated: false,
            required: '1.14.4-r1',
            problem: '',
          },
          core_log: { available: true, count: 0, limited: false },
          list_overlaps: [],
          foreign_sing_box: [],
          conflicts: [],
          memory: { total_kb: 239540, available_kb: 45476 },
          router_uptime: 1902323,
        },
      },
      {
        visibility: 'masked',
        notice: 'MASKED REPORT: review before sharing.',
        checks: '✓ Service — OK\n',
        log: 'forkop: [info] Forkop started\n',
        forkop_config: "config settings 'settings'\n",
        nftables: '',
        ip_rules: '105: from all fwmark 0x4000000/0x4000000 lookup forkop\n',
      },
    );

    expect(text.split('\n').slice(0, 7)).toEqual([
      'MASKED REPORT: review before sharing.',
      'Forkop diagnostic report · 2026-10-19 17:05',
      '',
      '== System ==',
      'Forkop 1.0.6 · sing-box-forkop 1.14.4-r1 (base)',
      'OpenWrt 25.12.5 r33051-f5dae5ece4 · Xiaomi Mi Router AX3000T',
      'Router up for 22 d · Memory: 44 MB of 234 MB free',
    ]);
    for (const heading of [
      '== Checks ==\n✓ Service — OK\n',
      '== Log ==\nforkop: [info] Forkop started\n',
      '== Forkop configuration ==',
      '== nftables ==\nempty\n',
      '== Routing rules ==',
    ]) {
      expect(text).toContain(heading);
    }
    expect(text).not.toContain('sing-box configuration');
  });
});
