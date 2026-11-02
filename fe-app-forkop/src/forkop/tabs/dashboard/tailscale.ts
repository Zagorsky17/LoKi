import { E } from '../../../helpers/element';
import { pageLanguage, relativeTime } from '../../../helpers/relativeTime';
import {
  renderLoaderCircleIcon24,
  renderRotateCcwIcon24,
} from '../../../icons';
import { latencyClassName } from '../../helpers/latencyClassName';
import { validateUrl } from '../../../validators/validateUrl';
import { CustomForkopMethods } from '../../methods';
import { ClashAPI } from '../../types';
import {
  copyWithToast,
  iconSvg,
  injectDetailsStyles,
  renderCloseRow,
} from './tailscaleDetails';

const REFRESH_INTERVAL_MS = 5000;
const STYLE_ID = 'forkop-tailscale-styles';

type Tone = 'ok' | 'warn' | 'error' | 'muted';

type EndpointLoad =
  | { endpoint: ClashAPI.TailscaleEndpoint }
  | { endpoint?: undefined; error?: string };

interface PeerPing {
  pending: boolean;
  pong?: ClashAPI.TailscalePong;
  error?: string;
}

// The last ping of each device by the address it was pinged at, kept across the refreshes.
interface PeerPings {
  results: Map<string, PeerPing>;
  ping: (address: string) => void;
}

function injectStyles() {
  injectDetailsStyles();
  if (document.getElementById(STYLE_ID)) {
    return;
  }

  document.head.appendChild(
    E(
      'style',
      { id: STYLE_ID },
      [
        // The URLTest and Fallback details' grid of parameters and rows of nodes.
        '.fkp-ts__params{display:grid;grid-template-columns:minmax(120px,max-content) minmax(0,1fr);gap:8px 16px;margin:0 0 18px}',
        '.fkp-ts__params > div{display:contents}',
        '.fkp-ts__params dt{color:var(--text-color-medium,#666);line-height:1.35}',
        '.fkp-ts__params dd{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 8px;min-inline-size:0;margin:0;overflow-wrap:anywhere}',
        '.fkp-ts__lines{display:grid;gap:4px;min-inline-size:0}',
        '.fkp-ts--ok{color:var(--success-color-medium,green)}',
        '.fkp-ts--warn{color:var(--warn-color-medium,#c80)}',
        '.fkp-ts--error{color:var(--error-color-medium,red)}',
        '.fkp-ts--muted{color:var(--text-color-medium,#666)}',
        '.fkp-ts__pending{font-size:12px}',
        '.fkp-ts__address{color:var(--primary-color-high,#337ab7);text-decoration:none}',
        '.fkp-ts__address:hover{text-decoration:underline}',
        '.fkp-ts__online{display:inline-flex;align-items:center;gap:6px}',
        '.fkp-ts__online::before{content:"";flex:none;inline-size:8px;block-size:8px;border-radius:50%;background:currentColor}',
        '.fkp-ts__devices-title{margin-bottom:8px;font-weight:600}',
        '.fkp-ts__devices{display:grid;gap:6px;max-block-size:min(46vh,460px);overflow-y:auto}',
        '.fkp-ts__device{display:flex;flex-wrap:wrap;align-items:center;column-gap:8px;row-gap:2px;padding:7px 8px;border-bottom:1px solid var(--border-color-low,#eee)}',
        '.fkp-ts__device-name{display:flex;flex-wrap:wrap;align-items:center;gap:2px 8px;flex:1 1 auto;min-inline-size:0}',
        '.fkp-ts__device-name b{overflow-wrap:anywhere}',
        '.fkp-ts__device-name > svg{flex:none;inline-size:14px;block-size:14px;color:var(--text-color-medium,#888)}',
        '.fkp-ts__dot{flex:none;inline-size:8px;block-size:8px;border-radius:50%;background:var(--success-color-medium,green)}',
        '.fkp-ts__who{display:inline-flex;align-items:center;gap:6px}',
        '.fkp-ts__who > svg{flex:none;inline-size:14px;block-size:14px;color:var(--text-color-medium,#888)}',
        '.fkp-ts__device-meta{display:flex;flex-wrap:wrap;align-items:center;gap:2px 8px;flex:0 1 auto;margin-left:auto}',
        '.fkp-ts__chip{padding:0 6px;border:1px solid currentColor;border-radius:4px;font-size:12px;line-height:18px;color:var(--text-color-medium,#888)}',
        '.fkp-ts__chip--active{color:var(--success-color-medium,green)}',
        // The dashboard's latency button, coloured by its classes: the theme draws .btn as a framed button.
        '.btn.fkp-ts__ping{display:inline-flex;align-items:center;gap:4px;margin:0 !important;padding:0 !important;border:none !important;background:transparent !important;box-shadow:none !important;font:inherit;line-height:inherit}',
        '.btn.fkp-ts__ping:hover,.btn.fkp-ts__ping:focus-visible{opacity:.7}',
        '.fkp-ts__ping svg{flex:none;inline-size:14px;block-size:14px}',
      ].join('\n'),
    ),
  );
}

function formatDate(seconds: number) {
  return new Date(seconds * 1000).toLocaleDateString(pageLanguage(), {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  });
}

function text(tone: Tone, value: string, title?: string) {
  return E(
    'span',
    title ? { class: `fkp-ts--${tone}`, title } : { class: `fkp-ts--${tone}` },
    value,
  );
}

function online() {
  return E('span', { class: 'fkp-ts--ok fkp-ts__online' }, _('Online'));
}

function renderStatus(endpoint: ClashAPI.TailscaleEndpoint) {
  switch (endpoint.state) {
    case 'Running':
      return endpoint.connected
        ? [online()]
        : [text('error', _('No connection to the coordination server'))];
    case 'NeedsLogin':
      return [
        text('warn', _('Waiting for sign-in')),
        ...(typeof endpoint.authURL === 'string' &&
        validateUrl(endpoint.authURL) === true
          ? [
              E(
                'a',
                {
                  href: endpoint.authURL,
                  target: '_blank',
                  rel: 'noopener noreferrer',
                },
                _('Sign in'),
              ),
            ]
          : []),
      ];
    case 'NeedsMachineAuth':
      return [text('warn', _('Waiting for approval in the console'))];
    case 'Stopped':
      return [text('muted', _('Stopped'))];
    default:
      return [text('muted', _('Starting'))];
  }
}

function approval(approved: boolean) {
  return approved
    ? text('ok', _('Approved'))
    : E(
        'span',
        { class: 'fkp-ts--warn fkp-ts__pending' },
        _('Waiting for approval in the console'),
      );
}

function onlineDot() {
  return E('span', {
    class: 'fkp-ts__dot',
    title: _('Online now'),
    'aria-label': _('Online now'),
  });
}

// A device of the tailnet as its row in the list starts.
function renderDevice(name: string, isOnline = false) {
  return E('span', { class: 'fkp-ts__who' }, [
    iconSvg('user'),
    name,
    ...(isOnline ? [onlineDot()] : []),
  ]);
}

function renderExitNodeInUse(endpoint: ClashAPI.TailscaleEndpoint) {
  const exitNode = endpoint.peers.find((peer) => peer.exitNode);
  if (exitNode) {
    return [
      renderDevice(exitNode.name, exitNode.online),
      ...(exitNode.online ? [] : [text('error', _('Offline'))]),
    ];
  }
  return endpoint.exitNode
    ? [renderDevice(endpoint.exitNode), text('warn', _('Not in use'))]
    : [text('warn', _('Not set'))];
}

function renderKeyExpiry(keyExpiry?: number) {
  if (!keyExpiry) {
    return text('muted', _('Does not expire'));
  }
  return keyExpiry * 1000 < Date.now()
    ? text('error', _('Expired %s').format(formatDate(keyExpiry)))
    : E('span', {}, _('Expires %s').format(formatDate(keyExpiry)));
}

// Each value copies itself when clicked.
function renderCopyable(values: string[]) {
  return values.flatMap((value, index) => [
    ...(index ? [text('muted', '·')] : []),
    E(
      'a',
      {
        href: '#',
        class: 'fkp-ts__address',
        title: _('Copy'),
        click: (ev: Event) => {
          ev.preventDefault();
          copyWithToast(value);
        },
      },
      value,
    ),
  ]);
}

function param(label: string, children: Array<Node | string>) {
  return E('div', {}, [E('dt', {}, label), E('dd', {}, children)]);
}

function renderParams(endpoint: ClashAPI.TailscaleEndpoint) {
  const running = endpoint.state === 'Running';
  const params = [param(_('Status'), renderStatus(endpoint))];

  if (endpoint.name) {
    params.push(param(_('Name in the console'), [renderDevice(endpoint.name)]));
  }
  if (endpoint.addresses.length) {
    params.push(param(_('Addresses'), renderCopyable(endpoint.addresses)));
  }
  if (endpoint.tailnet) {
    params.push(param(_('Tailnet'), renderCopyable([endpoint.tailnet])));
  }
  if (running) {
    params.push(
      param(
        _('Exit node'),
        endpoint.advertisesExitNode
          ? [approval(endpoint.exitNodeApproved)]
          : renderExitNodeInUse(endpoint),
      ),
    );
  }
  if (endpoint.routes.length) {
    params.push(
      param(_('Advertise routes'), [
        E(
          'div',
          { class: 'fkp-ts__lines' },
          endpoint.routes.map((route) =>
            E('div', {}, [`${route.prefix} · `, approval(route.approved)]),
          ),
        ),
      ]),
    );
  }
  if (running) {
    params.push(param(_('Node key'), [renderKeyExpiry(endpoint.keyExpiry)]));
  }
  if (endpoint.health.length) {
    params.push(
      param(_('Warnings'), [
        E(
          'div',
          { class: 'fkp-ts__lines' },
          endpoint.health.map((message) => E('div', {}, message)),
        ),
      ]),
    );
  }

  return E('dl', { class: 'fkp-ts__params' }, params);
}

function formatLatency(latency: number) {
  return latency < 1 ? '<1ms' : `${Math.round(latency)}ms`;
}

// The dashboard's latency button: the last answer, N/A before one and after a failure.
function renderPing(address: string, pings: PeerPings) {
  const result = pings.results.get(address);
  const pending = Boolean(result?.pending);
  return E(
    'button',
    {
      type: 'button',
      class: `btn fkp-ts__ping ${latencyClassName(result?.pong?.latency ?? 0)}`,
      title: result?.error || _('Ping the device'),
      'aria-label': _('Ping the device'),
      'aria-busy': pending ? 'true' : undefined,
      disabled: pending ? true : undefined,
      click: () => pings.ping(address),
    },
    [
      pending ? renderLoaderCircleIcon24() : renderRotateCcwIcon24(),
      E(
        'span',
        {},
        result?.pong ? formatLatency(result.pong.latency) : _('N/A'),
      ),
    ],
  );
}

// How long ago, as the dashboard ages a subscription, and the moment on hover.
function renderLastSeen(lastSeen: number) {
  return text(
    'muted',
    relativeTime(lastSeen, 'short'),
    _('Last online %s').format(
      new Date(lastSeen * 1000).toLocaleString(pageLanguage(), {
        dateStyle: 'medium',
        timeStyle: 'short',
      }),
    ),
  );
}

function renderPeerMeta(peer: ClashAPI.TailscalePeer, pings: PeerPings) {
  if (!peer.online) {
    return [
      peer.lastSeen
        ? renderLastSeen(peer.lastSeen)
        : text('muted', _('Offline')),
    ];
  }
  return peer.addresses[0] ? [renderPing(peer.addresses[0], pings)] : [];
}

function renderPeer(peer: ClashAPI.TailscalePeer, pings: PeerPings) {
  return E('div', { class: 'fkp-ts__device', title: peer.dnsName || '' }, [
    E('div', { class: 'fkp-ts__device-name' }, [
      iconSvg('user'),
      E('b', {}, peer.name),
      ...(peer.online ? [onlineDot()] : []),
      ...(peer.addresses[0] ? [text('muted', peer.addresses[0])] : []),
      ...(peer.exitNodeOption || peer.exitNode
        ? [
            E(
              'span',
              {
                class: peer.exitNode
                  ? 'fkp-ts__chip fkp-ts__chip--active'
                  : 'fkp-ts__chip',
              },
              _('Exit node'),
            ),
          ]
        : []),
      ...(peer.subnets?.length
        ? [text('muted', peer.subnets.join(', '), _('Subnets'))]
        : []),
    ]),
    E('div', { class: 'fkp-ts__device-meta' }, renderPeerMeta(peer, pings)),
  ]);
}

function renderPeers(peers: ClashAPI.TailscalePeer[], pings: PeerPings) {
  return E('div', {}, [
    E('div', { class: 'fkp-ts__devices-title' }, _('Devices')),
    peers.length
      ? E(
          'div',
          { class: 'fkp-ts__devices' },
          peers.map((peer) => renderPeer(peer, pings)),
        )
      : E(
          'div',
          { class: 'fkp-details__empty' },
          _('No other devices in the tailnet'),
        ),
  ]);
}

export function renderTailscaleContent(
  load: EndpointLoad,
  notRunning: string,
  pings: PeerPings,
) {
  if (!load.endpoint) {
    return [
      E(
        'div',
        { class: 'fkp-details__empty' },
        load.error
          ? _('Failed to get the Tailscale state: %s').format(load.error)
          : notRunning,
      ),
    ];
  }
  return [
    renderParams(load.endpoint),
    ...(load.endpoint.state === 'Running'
      ? [renderPeers(load.endpoint.peers, pings)]
      : []),
  ];
}

async function loadTailscaleEndpoint(tag: string): Promise<EndpointLoad> {
  const response = await CustomForkopMethods.getClashApiTailscale();
  if (!response.success) {
    return { error: response.error };
  }
  const endpoint = response.data?.endpoints?.find((item) => item.tag === tag);
  return endpoint ? { endpoint } : {};
}

async function pingPeer(tag: string, address: string): Promise<PeerPing> {
  const response = await CustomForkopMethods.pingClashApiTailscalePeer(
    tag,
    address,
  );
  if (response.success) {
    return { pending: false, pong: response.data };
  }
  return {
    pending: false,
    error: response.status === 504 ? _('no answer') : response.error,
  };
}

// Refreshed while the dialog shows: a device coming online, an approval in the console. LuCI
// hides a closed dialog without removing it, so the overlay tells whether it still shows.
export function showTailscaleDetailsModal(
  title: string,
  tag: string,
  notRunning: string,
) {
  injectStyles();
  const content = E('div', { class: 'fkp-details' }, [
    E('em', { class: 'spinning' }, _('Loading…')),
  ]);
  ui.showModal(title, [content, renderCloseRow()]);

  const shows = () =>
    content.isConnected &&
    document.body.classList.contains('modal-overlay-active');
  let load: EndpointLoad | undefined;
  const pings: PeerPings = {
    results: new Map(),
    ping: (address) => {
      pings.results.set(address, {
        ...pings.results.get(address),
        pending: true,
      });
      render();
      void pingPeer(tag, address).then((result) => {
        pings.results.set(address, result);
        render();
      });
    },
  };
  const render = () => {
    if (load && shows()) {
      dom.content(content, renderTailscaleContent(load, notRunning, pings));
    }
  };

  let timer = 0;
  const refresh = () => {
    if (!shows()) {
      window.clearInterval(timer);
      return;
    }
    void loadTailscaleEndpoint(tag).then((next) => {
      load = next;
      render();
    });
  };
  refresh();
  timer = window.setInterval(refresh, REFRESH_INTERVAL_MS);
}
