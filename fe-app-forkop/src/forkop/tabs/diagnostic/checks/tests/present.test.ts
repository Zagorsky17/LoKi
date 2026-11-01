// Modified for LoKi on 2026-11-01: report known list overlaps without changing routing.
import { describe, expect, it, vi } from 'vitest';

import { summarize } from '../present';
import { presentService } from '../service';
import { presentDns } from '../dns';
import { presentTraffic, runTrafficCheck } from '../traffic';
import { ForkopShellMethods, RemoteFakeIPMethods } from '../../../../methods';
import { presentServers } from '../servers';
import type { Forkop } from '../../../../types';

function service(
  overrides: Partial<Forkop.ServiceCheckResult> = {},
): Forkop.ServiceCheckResult {
  return {
    running: true,
    uptime: 8100,
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
    ...overrides,
  };
}

describe('a group summary', () => {
  it('takes the state of its worst finding and says only how bad that is', () => {
    const passed = { state: 'success' as const, key: 'A', value: '1' };
    const warned = { state: 'warning' as const, key: 'Memory', value: 'low' };
    const failed = { state: 'error' as const, key: 'DNS', value: 'silent' };

    expect(summarize([passed])).toEqual({
      state: 'success',
      description: 'Checks passed',
    });
    expect(summarize([passed, warned])).toEqual({
      state: 'warning',
      description: 'Issues detected',
    });
    expect(summarize([warned, passed, failed])).toEqual({
      state: 'error',
      description: 'Checks failed',
    });
  });
});

describe('informational findings', () => {
  it('never masks a warning or error and does not change the group status by its position', () => {
    const info = { state: 'info' as const, key: 'Browser', value: 'observed' };
    expect(summarize([info])).toEqual({
      state: 'success',
      description: 'Checks passed',
    });
    for (const state of ['warning', 'error'] as const) {
      const problem = { state, key: 'Router', value: 'failed' };
      expect(summarize([info, problem]).state).toBe(state);
      expect(summarize([problem, info]).state).toBe(state);
    }
  });
});

describe('the service check', () => {
  it('passes a running Forkop with nothing in its way, one line per question', () => {
    expect(presentService(service())).toEqual([
      { state: 'success', key: 'Forkop', value: 'running for 2 h 15 min' },
      {
        state: 'success',
        key: 'Core',
        value: 'sing-box-forkop 1.14.4-r1 (base)',
      },
      {
        state: 'success',
        key: 'Core log',
        value: 'No error messages found in the last 60 seconds',
      },
      { state: 'success', key: 'Conflicts', value: 'none found' },
      { state: 'success', key: 'Memory', value: '44 MB of 234 MB free' },
    ]);
  });

  it('warns about recorded errors, incomplete data and failed reads without displaying log text', () => {
    const item = (core_log: Forkop.ServiceCheckResult['core_log']) =>
      presentService(service({ core_log })).find(
        (value) => value.key === 'Core log',
      );
    expect(item({ available: true, count: 12, limited: false })).toEqual({
      state: 'warning',
      key: 'Core log',
      value: '12 error messages found in the last 60 seconds',
    });
    expect(item({ available: true, count: 0, limited: true })).toMatchObject({
      state: 'warning',
      value:
        'At least 0 error messages in the last 60 seconds; log data incomplete',
    });
    expect(item({ available: false, count: 0, limited: false })).toMatchObject({
      state: 'warning',
      value: 'Log data unavailable',
    });
    expect(
      item(undefined as unknown as Forkop.ServiceCheckResult['core_log']),
    ).toMatchObject({
      state: 'warning',
      value: 'Log data unavailable',
    });
  });

  it('warns about list sources without hiding service failures or inferring identical contents', () => {
    const items = presentService(
      service({
        running: false,
        list_overlaps: [
          {
            section: 'MAIN',
            builtin: 'telegram',
            external: 'forkop-lists/telegram.srs',
            relation: 'same_source',
          },
          {
            section: '<img src=x onerror=alert(1)>',
            builtin: 'ru_blocked_all',
            external: 'itdog/meta.srs',
            relation: 'possible_overlap',
          },
        ],
      }),
    );
    expect(summarize(items).state).toBe('error');
    const warnings = items.filter((item) => item.key.startsWith('Lists in '));
    expect(warnings).toEqual([
      {
        state: 'warning',
        key: 'Lists in MAIN',
        value:
          'External list forkop-lists/telegram.srs uses the same source as Telegram; review the section lists',
      },
      {
        state: 'warning',
        key: 'Lists in <img src=x onerror=alert(1)>',
        value:
          'External list itdog/meta.srs may overlap RU Blocked (All); compare domains and subnets before removing a list',
      },
    ]);
  });

  it('gives the error that kept Forkop from running, if one did', () => {
    expect(
      presentService(
        service({
          running: false,
          uptime: -1,
          last_error: 'Port 9090 is busy',
        }),
      )[0],
    ).toEqual({
      state: 'error',
      key: 'Forkop',
      value: 'not running: Port 9090 is busy',
    });
    expect(
      presentService(service({ running: false, uptime: -1 }))[0].value,
    ).toBe('not running');
  });

  it('fails a core that is not sing-box-forkop, an old one, or one Forkop cannot run on', () => {
    const core = (value: Partial<Forkop.ServiceCheckResult['core']>) =>
      presentService(service({ core: { ...service().core, ...value } })).find(
        (item) => item.key === 'Core',
      );
    expect(core({ installed: false, binary: '', version: '' })).toEqual({
      state: 'error',
      key: 'Core',
      value: 'sing-box-forkop is not installed',
    });
    expect(
      core({
        binary: '',
        version: '',
        problem:
          "Failed to read the tags sing-box was built with from 'sing-box version'. Reinstall sing-box-forkop",
      })?.value,
    ).toBe(
      "Failed to read the tags sing-box was built with from 'sing-box version'. Reinstall sing-box-forkop",
    );
    expect(core({ binary: '1.12.22', version: '', variant: '' })).toEqual({
      state: 'error',
      key: 'Core',
      value: 'sing-box 1.12.22, not sing-box-forkop',
    });
    expect(
      core({
        binary: '1.13.18-extended-2.6.5-f165',
        version: '1.13.18-extended-2.6.5-f165',
        variant: '',
        outdated: true,
      }),
    ).toEqual({
      state: 'error',
      key: 'Core',
      value:
        'sing-box-forkop 1.13.18-extended-2.6.5-f165 is outdated: 1.14.4-r1 or newer is needed',
    });
    expect(
      core({
        variant: 'custom',
        problem:
          'sing-box was built with with_wireguard but without with_gvisor',
      }),
    ).toEqual({
      state: 'error',
      key: 'Core',
      value: 'sing-box was built with with_wireguard but without with_gvisor',
    });
    expect(
      core({ binary: '1.14.4-r1+2', version: '1.14.4-r1+2', variant: '' })
        ?.value,
    ).toBe('sing-box-forkop 1.14.4-r1+2');
    expect(core({})).toEqual({
      state: 'success',
      key: 'Core',
      value: 'sing-box-forkop 1.14.4-r1 (base)',
    });
  });

  it('names every program that intercepts what Forkop does', () => {
    const items = presentService(
      service({
        conflicts: [
          { table: 'inet PodkopTable', kind: 'tproxy' },
          { table: 'ip adguard', kind: 'dns' },
        ],
        foreign_sing_box: [812, 990],
      }),
    ).filter((item) => item.key === 'Conflicts');
    expect(items.map((item) => [item.state, item.value])).toEqual([
      ['error', 'inet PodkopTable intercepts traffic'],
      ['error', 'ip adguard takes DNS queries before Forkop'],
      ['error', 'another sing-box is running (PID 812, 990)'],
    ]);
  });

  it('warns about memory only while it is nearly gone', () => {
    const memory = (overrides: Partial<Forkop.ServiceCheckResult>) =>
      presentService(service(overrides)).find((item) => item.key === 'Memory');
    expect(memory({})).toMatchObject({
      state: 'success',
      value: '44 MB of 234 MB free',
    });
    expect(
      memory({ memory: { total_kb: 131072, available_kb: 10240 } }),
    ).toMatchObject({ state: 'warning', value: '10 MB of 128 MB free' });
  });
});

function dns(
  overrides: Partial<Forkop.DnsCheckResult> = {},
): Forkop.DnsCheckResult {
  return {
    main: { servers: '77.88.8.8', answered: true, status: 'NOERROR', ms: 12 },
    bootstrap: null,
    local: { answered: true, status: 'NOERROR', ms: 0 },
    ...overrides,
  };
}

describe('the DNS check', () => {
  it('shows each resolver the core uses with how fast it answered', () => {
    expect(
      presentDns(
        dns({
          bootstrap: {
            servers: '1.1.1.1',
            host: 'dns.example',
            answered: true,
            ms: 30,
          },
        }),
      ),
    ).toEqual([
      { state: 'success', key: 'Main DNS', value: '77.88.8.8 · 12 ms' },
      { state: 'success', key: 'Bootstrap DNS', value: '1.1.1.1 · 30 ms' },
      { state: 'success', key: 'Local DNS', value: 'dnsmasq · 0 ms' },
    ]);
  });

  it('tells a server that is silent from one that fails', () => {
    expect(
      presentDns(
        dns({
          main: { servers: '1.1.1.1', answered: false, status: '', ms: -1 },
        }),
      )[0].value,
    ).toBe('1.1.1.1 does not answer');
    expect(
      presentDns(
        dns({
          main: {
            servers: '1.1.1.1',
            answered: false,
            status: 'SERVFAIL',
            ms: 3,
          },
        }),
      )[0].value,
    ).toBe('1.1.1.1 answers with SERVFAIL');
  });

  it('says when dnsmasq is gone', () => {
    const local = { answered: false, status: '', ms: -1 };
    expect(presentDns(dns({ local }))[1]).toEqual({
      state: 'error',
      key: 'Local DNS',
      value: 'dnsmasq does not answer',
    });
  });
});

function traffic(
  overrides: Partial<Forkop.TrafficCheckResult> = {},
): Forkop.TrafficCheckResult {
  return {
    router: {
      excluded: false,
      dns_fakeip: true,
      answered: true,
      fakeip: true,
      ip: '46.138.78.196',
    },
    exit: { section: 'Main', answered: true, ip: '38.107.233.96' },
    ...overrides,
  };
}

describe('the traffic check', () => {
  it('shows the exit of the first section beside the direct one', () => {
    expect(presentTraffic(traffic(), { fakeip: true })).toEqual([
      { state: 'success', key: 'Router', value: 'goes through Forkop' },
      {
        state: 'success',
        key: 'Exit via "Main"',
        value: '38.107.233.96, direct 46.138.78.196',
      },
      { state: 'success', key: 'This device', value: 'goes through Forkop' },
    ]);
  });

  it('warns when the section leaves from the direct address', () => {
    expect(
      presentTraffic(
        traffic({
          exit: { section: 'Main', answered: true, ip: '46.138.78.196' },
        }),
        { fakeip: true },
      )[1],
    ).toMatchObject({
      state: 'warning',
      value: '46.138.78.196, the same as direct',
    });
  });

  it('keeps a negative browser result informational and an unanswered check a warning', () => {
    expect(presentTraffic(traffic(), { fakeip: false })[2]).toMatchObject({
      state: 'info',
      value:
        'Browser check did not confirm FakeIP; router results are shown separately',
    });
    expect(presentTraffic(traffic(), null)[2]).toMatchObject({
      state: 'warning',
      value: 'not checked: no answer',
    });
  });

  it('does not turn successful router checks into a group warning because of the browser', () => {
    const items = presentTraffic(traffic(), { fakeip: false });
    expect(items.map((item) => item.state)).toEqual([
      'success',
      'success',
      'info',
    ]);
    expect(summarize(items)).toEqual({
      state: 'success',
      description: 'Checks passed',
    });
    expect(summarize(presentTraffic(traffic(), null)).state).toBe('warning');
  });

  it.each([
    [
      { router: { ...traffic().router, dns_fakeip: false, fakeip: false } },
      'warning',
    ],
    [
      { router: { ...traffic().router, answered: false, fakeip: false } },
      'warning',
    ],
    [{ router: { ...traffic().router, fakeip: false } }, 'error'],
    [{ exit: { ...traffic().exit!, answered: false } }, 'warning'],
    [{ exit: { ...traffic().exit!, ip: traffic().router.ip } }, 'warning'],
  ] as const)(
    'preserves router and exit findings next to an informational browser result: %j',
    (overrides, state) => {
      const items = presentTraffic(traffic(overrides), { fakeip: false });
      expect(items[items.length - 1]?.state).toBe('info');
      expect(summarize(items).state).toBe(state);
    },
  );

  it.each([undefined, null, 0, 1, 'false', 'true', {}, []])(
    'treats a malformed browser flag %j as unavailable rather than informational or successful',
    async (fakeip) => {
      const router = vi
        .spyOn(ForkopShellMethods, 'checkTraffic')
        .mockResolvedValue({ success: true, data: traffic() });
      const browser = vi
        .spyOn(RemoteFakeIPMethods, 'getFakeIpCheck')
        .mockResolvedValue({
          success: true,
          data: { fakeip, IP: '192.0.2.1' },
        } as Awaited<ReturnType<typeof RemoteFakeIPMethods.getFakeIpCheck>>);
      try {
        const result = await runTrafficCheck();
        expect(result.state).toBe('warning');
        expect(result.items[result.items.length - 1]).toMatchObject({
          state: 'warning',
          value: 'not checked: no answer',
        });
      } finally {
        router.mockRestore();
        browser.mockRestore();
      }
    },
  );

  it.each([false, true])(
    'accepts an actual boolean browser flag %j',
    async (fakeip) => {
      const router = vi
        .spyOn(ForkopShellMethods, 'checkTraffic')
        .mockResolvedValue({ success: true, data: traffic() });
      const browser = vi
        .spyOn(RemoteFakeIPMethods, 'getFakeIpCheck')
        .mockResolvedValue({
          success: true,
          data: { fakeip, IP: '192.0.2.1' },
        });
      try {
        const result = await runTrafficCheck();
        expect(result.state).toBe('success');
        expect(result.items[result.items.length - 1].state).toBe(
          fakeip ? 'success' : 'info',
        );
      } finally {
        router.mockRestore();
        browser.mockRestore();
      }
    },
  );

  it('finds where the router itself leaves Forkop out', () => {
    const router = (value: Partial<Forkop.TrafficCheckResult['router']>) =>
      presentTraffic(
        traffic({ router: { ...traffic().router, ...value }, exit: null }),
        { fakeip: true },
      )[0];
    expect(router({ dns_fakeip: false, fakeip: false }).value).toBe(
      'resolves past Forkop',
    );
    expect(router({ fakeip: false })).toMatchObject({
      state: 'error',
      value: 'goes past Forkop',
    });
    expect(router({ answered: false, fakeip: false }).value).toBe(
      'not checked: the check service did not answer',
    );
  });

  it('says the router is excluded instead of judging a path it deliberately skips', () => {
    expect(
      presentTraffic(
        traffic({
          router: {
            excluded: true,
            dns_fakeip: false,
            answered: false,
            fakeip: false,
            ip: '',
          },
          exit: null,
        }),
        { fakeip: true },
      ).slice(0, 2),
    ).toEqual([
      { state: 'success', key: 'Router', value: 'excluded from routing' },
      { state: 'success', key: 'This device', value: 'goes through Forkop' },
    ]);
  });
});

function server(
  overrides: Partial<Forkop.ServerCheckItem> = {},
): Forkop.ServerCheckItem {
  return {
    label: 'Main',
    protocol: 'vless',
    port: 443,
    transports: 'tcp',
    runtime: true,
    listening: true,
    owners: '',
    exposed: true,
    open_firewall: true,
    firewall_open: true,
    public_host: 'vpn.example',
    public_ips: '2a00:1450::7',
    resolved: 1,
    public: 1,
    matches_wan: 1,
    ...overrides,
  };
}

describe('the server check', () => {
  const present = (overrides: Partial<Forkop.ServerCheckItem>) =>
    presentServers({
      wan: '100.64.1.2 2a00:1450::7',
      behind_cgnat: false,
      items: [server(overrides)],
    });

  it('is one line for a server that works', () => {
    expect(present({})).toEqual([
      { state: 'success', key: 'Main', value: '443/tcp · vpn.example' },
    ]);
    expect(
      present({ transports: 'tcp udp', protocol: 'shadowsocks' })[0].value,
    ).toBe('443/tcp+udp · vpn.example');
  });

  it('says why a server does not listen', () => {
    expect(present({ listening: false, owners: '812/nginx' })[0].value).toBe(
      'port 443/tcp is taken by 812/nginx',
    );
    expect(
      present({ listening: true, runtime: false, owners: '1203/dropbear' })[0]
        .value,
    ).toBe('port 443/tcp is taken by 1203/dropbear');
    expect(present({ listening: false, runtime: false })[0].value).toBe(
      'not in the running configuration',
    );
    expect(present({ listening: false })[0].value).toBe(
      'does not listen on 443/tcp',
    );
  });

  it('says when the firewall keeps the port closed', () => {
    expect(present({ firewall_open: false })).toEqual([
      {
        state: 'error',
        key: 'Main',
        value: '443/tcp is closed in the firewall',
      },
    ]);
  });

  it('checks that the public address leads to this router', () => {
    expect(
      present({
        public_host: 'vpn.example',
        public_ips: '46.138.78.196',
        matches_wan: 0,
      })[0].value,
    ).toBe(
      'vpn.example leads to 46.138.78.196, the router has 100.64.1.2 2a00:1450::7',
    );
    expect(
      present({
        public_host: '100.64.1.2',
        public_ips: '100.64.1.2',
        public: 0,
      })[0].value,
    ).toBe('100.64.1.2 is not a public address');
    expect(present({ resolved: 0 })[0].value).toBe(
      'vpn.example does not resolve',
    );
    expect(
      present({ protocol: 'json_inbound', public_host: '', exposed: false }),
    ).toEqual([{ state: 'success', key: 'Main', value: '443/tcp' }]);
  });

  it('asks nothing about the internet of a server kept to the LAN', () => {
    const lan = [{ state: 'success', key: 'Main', value: '443/tcp' }];
    expect(
      present({ open_firewall: false, firewall_open: false, public_host: '' }),
    ).toEqual(lan);
    expect(present({ exposed: false, public_host: '' })).toEqual(lan);
    expect(
      present({ open_firewall: false, firewall_open: true, resolved: 0 }),
    ).toEqual([
      {
        state: 'warning',
        key: 'Main',
        value: 'vpn.example does not resolve',
      },
    ]);
  });

  it("says once that the router is behind the provider's NAT", () => {
    const behind = (items: Forkop.ServerCheckItem[]) =>
      presentServers({ wan: '100.116.152.154', behind_cgnat: true, items });
    const reached = server({
      public_host: 'vpn.example',
      public_ips: '46.138.78.196',
      matches_wan: -1,
    });

    expect(behind([reached, server({ label: 'Second' })])).toEqual([
      {
        state: 'warning',
        key: 'Router',
        value:
          "behind the provider's NAT (100.116.152.154), unreachable from the internet",
      },
      { state: 'success', key: 'Main', value: '443/tcp · vpn.example' },
      { state: 'success', key: 'Second', value: '443/tcp · vpn.example' },
    ]);
    expect(
      behind([server({ open_firewall: false, firewall_open: false })]),
    ).toEqual([
      { state: 'success', key: 'Main', value: '443/tcp · vpn.example' },
    ]);
  });
});

describe('the Tailscale server check', () => {
  const present = (
    overrides: Partial<Forkop.TailscaleServerCheckItem> = {},
    behind_cgnat = false,
  ) =>
    presentServers({
      wan: '100.116.152.154',
      behind_cgnat,
      items: [
        {
          label: 'Tail',
          protocol: 'tailscale',
          runtime: true,
          state: 'Running',
          connected: true,
          name: 'forkop-3',
          exit_node_pending: false,
          pending_routes: '',
          key_expired: false,
          ...overrides,
        },
      ],
    });

  it('names the device the tailnet knows once it is online', () => {
    expect(present()).toEqual([
      { state: 'success', key: 'Tail', value: 'online · forkop-3' },
    ]);
  });

  it('fails a server that is not in the tailnet', () => {
    expect(present({ runtime: false, state: '' })[0]).toEqual({
      state: 'error',
      key: 'Tail',
      value: 'not in the running configuration',
    });
    expect(present({ state: 'NeedsLogin' })[0].value).toBe(
      'waiting for sign-in',
    );
    expect(present({ connected: false })[0].value).toBe(
      'no connection to the coordination server',
    );
    expect(present({ key_expired: true })[0].value).toBe('node key expired');
  });

  it('warns of what waits for approval in the console', () => {
    expect(
      present({ exit_node_pending: true, pending_routes: '192.168.1.1/32' }),
    ).toEqual([
      {
        state: 'warning',
        key: 'Tail',
        value: 'exit node waiting for approval in the console',
      },
      {
        state: 'warning',
        key: 'Tail',
        value: '192.168.1.1/32 waiting for approval in the console',
      },
    ]);
  });

  it('needs no open port, so the provider NAT is no concern of it', () => {
    expect(present({}, true)).toEqual([
      { state: 'success', key: 'Tail', value: 'online · forkop-3' },
    ]);
  });
});
