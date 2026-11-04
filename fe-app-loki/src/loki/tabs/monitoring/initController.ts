import {
  canUseDirectClashApi,
  getClashSocketUrl,
} from '../../../helpers/getClashApiUrl';
import { onMount } from '../../../helpers/onMount';
import { resetClashApiTransport } from '../../methods/custom/clashApi';
import { pollDelayForDuration } from '../../helpers/pollDelay';
import { shouldCopyFullMonitoringValue } from './valueCopy';
import { createPollChain } from '../../helpers/pollChain';
import { isDocumentVisible } from '../../../helpers/isDocumentVisible';
import { createTabLifecycle } from '../../helpers/tabLifecycle';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { showToast } from '../../../helpers/showToast';
import { renderSearchIcon24 } from '../../../icons';
import { CustomLokiMethods } from '../../methods';
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { loadLocalDevices } from '../../cbi/localDevices';
import { logger, socket, store, StoreType } from '../../services';
import { Loki } from '../../types';
import { E } from '../../../helpers/element';
import {
  ConnectionListItem,
  ConnectionListSort,
  ConnectionSortColumn,
  renderConnectionList,
  renderConnectionListState,
} from './connectionList';
import { formatEndpoint } from './endpoint';
import { closeConnections } from './closeConnections';
import {
  compareSources,
  ConnectionSource,
  describeSource,
  sourceLabel,
} from './source';

type MonitoringTabId = 'active' | 'closed';

interface ClashConnectionMetadata {
  destinationIP?: string;
  destinationPort?: string | number;
  host?: string;
  network?: string;
  processPath?: string;
  sourceIP?: string;
  sourcePort?: string | number;
  type?: string;
  user?: string;
}

interface ClashConnection {
  chains?: string[];
  download?: number;
  id?: string;
  metadata?: ClashConnectionMetadata;
  rule?: string;
  rulePayload?: string;
  start?: string;
  upload?: number;
}

interface ClashConnectionsPayload {
  connections?: ClashConnection[];
}

interface MonitoredConnection extends ClashConnection {
  id: string;
  closedAt?: number;
  lastSeenAt: number;
}

function normalizeConnectionsPayload(value: unknown): ClashConnectionsPayload {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }

  return value as ClashConnectionsPayload;
}

const RENDER_INTERVAL_MS = 500;
const CONNECTIONS_RPC_POLL_INTERVAL_MS = 1500;
const CONNECTIONS_RPC_POLL_BACKOFF_MAX_MS = 30000;
// The slowest the poll may get when each answer is expensive.
const CONNECTIONS_POLL_DUTY_MAX_MS = 15000;
// A socket to a port that drops packets neither connects nor fails until the browser's own
// timeout, so after this the poll covers the wait.
const CONNECTIONS_SOCKET_GRACE_MS = 2000;
const CLOSED_CONNECTION_LIMIT = 300;
const ALL_FILTER_VALUE = '';
const DIRECT_ROUTE_TAG = 'direct-out';

interface ConnectionRoute {
  tag: string;
  label: string;
}

let monitoringMounted = false;
let monitoringMountId = 0;
let monitoringLifecycleRegistered = false;
let monitoringControllerInitialized = false;
let renderTimer: ReturnType<typeof setInterval> | null = null;
let connectionsSocketUrl = '';
let connectionsUpdatesId = 0;
let connectionsSocketGraceTimer: ReturnType<typeof setTimeout> | null = null;
let lastConnectionsPollDurationMs = 0;
let pendingConnectionsPayload: ClashConnectionsPayload | null = null;

let activeTab: MonitoringTabId = 'active';
let selectedDeviceFilter = ALL_FILTER_VALUE;
let selectedRouteFilter = ALL_FILTER_VALUE;
let searchQuery = '';
let connectionSort: ConnectionListSort | null = null;
let localDeviceNames: Record<string, string> = {};
let routeLabels: Record<string, string> = {};
let sectionTags: string[] = [];
let sectionTagsLongestFirst: string[] = [];
let filterSignatures: Record<string, string> = {};
let loading = true;
let failed = false;
let closingAll = false;
let monitoringPaused = false;
let selectionHeld = false;
let monitoringPausedAt: number | null = null;
let consecutivePollFailures = 0;

const activeConnections = new Map<string, MonitoredConnection>();
const closedConnections = new Map<string, MonitoredConnection>();
const closingConnectionIds = new Set<string>();

function normalizeString(value?: string | number | null): string {
  return value == null ? '' : String(value).trim();
}

function getDisplayName(section: Loki.ConfigSection) {
  return normalizeString(section.label) || section['.name'];
}

// A section's display name is its tag, and the outbounds inside it are tagged under it.
function buildRouteDisplayNames(sections: Loki.ConfigSection[]) {
  const labels: Record<string, string> = {
    [DIRECT_ROUTE_TAG]: _('Direct'),
  };
  const routeSectionTags: string[] = [];
  sections
    .filter((section) => section['.type'] === 'section')
    .filter((section) => section.enabled !== '0')
    .forEach((section) => {
      const sectionName = section['.name'];
      const displayName = getDisplayName(section);

      if (!sectionName || !displayName) {
        return;
      }

      routeSectionTags.push(displayName);
      labels[displayName] = displayName;
    });

  routeLabels = labels;
  sectionTags = routeSectionTags;
  sectionTagsLongestFirst = [...routeSectionTags].sort(
    (a, b) => b.length - a.length,
  );
}

function getKnownRouteTag(tag: string): string {
  if (!tag || routeLabels[tag]) {
    return tag;
  }

  return (
    sectionTagsLongestFirst.find((sectionTag) =>
      tag.startsWith(`${sectionTag}/`),
    ) || ''
  );
}

function getRouteTagFromRule(rule?: string): string {
  const match = normalizeString(rule).match(/=>\s*route\(([^)]+)\)/);
  return normalizeString(match?.[1]).replace(/^['"]|['"]$/g, '');
}

function parseStartedAt(connection: MonitoredConnection): number {
  const startedAt = Date.parse(connection.start || '');
  return Number.isFinite(startedAt) ? startedAt : connection.lastSeenAt;
}

function formatDuration(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const pad = (value: number) => String(value).padStart(2, '0');

  if (hours > 0) {
    return `${hours}:${pad(minutes)}:${pad(seconds)}`;
  }

  return `${minutes}:${pad(seconds)}`;
}

function getConnectionDuration(
  connection: MonitoredConnection,
  now: number,
): number {
  const finishedAt = connection.closedAt || monitoringPausedAt || now;

  return finishedAt - parseStartedAt(connection);
}

function formatConnectionDuration(connection: MonitoredConnection): string {
  return formatDuration(getConnectionDuration(connection, Date.now()));
}

function formatBytes(value?: number): string {
  return prettyBytes(Number.isFinite(value) ? Number(value) : 0);
}

function getSource(connection: ClashConnection): ConnectionSource {
  return describeSource(connection, {
    devices: localDeviceNames,
  });
}

function getTargetCellParts(connection: MonitoredConnection): {
  primary: string;
  searchValue: string;
} {
  const metadata = connection.metadata || {};
  const host = normalizeString(metadata.host);
  const destinationIp = normalizeString(metadata.destinationIP);
  const port = metadata.destinationPort;
  const primaryTarget = host || destinationIp;
  const primary = primaryTarget ? formatEndpoint(primaryTarget, port) : '-';

  return {
    primary,
    searchValue: [primary, host, destinationIp].filter(Boolean).join(' '),
  };
}

// The core lists the chain from the outbound that dialed back to the rule's, so the rule's
// outermost known outbound names the route.
function getRoute(connection: MonitoredConnection): ConnectionRoute | null {
  const chains = Array.isArray(connection.chains) ? connection.chains : [];
  const ruleTag = getRouteTagFromRule(connection.rule);
  const tag =
    [...chains].reverse().map(getKnownRouteTag).find(Boolean) ||
    getKnownRouteTag(ruleTag) ||
    ruleTag;

  return tag ? { tag, label: routeLabels[tag] || tag } : null;
}

function getNetwork(connection: MonitoredConnection): string {
  return normalizeString(connection.metadata?.network).toLowerCase() || '-';
}

function sortConnections(
  connections: MonitoredConnection[],
  tab: MonitoringTabId,
): MonitoredConnection[] {
  return [...connections].sort((a, b) => {
    if (tab === 'closed') {
      return (b.closedAt || 0) - (a.closedAt || 0);
    }

    return parseStartedAt(b) - parseStartedAt(a);
  });
}

// The active list's own order is the time column's, shortest first; the closed list's is when
// each closed, which no column shows.
function getShownSort(): ConnectionListSort | null {
  return (
    connectionSort ??
    (activeTab === 'active' ? { column: 'time', descending: false } : null)
  );
}

function getSortValue(
  connection: MonitoredConnection,
  column: ConnectionSortColumn,
  now: number,
): number {
  if (column === 'time') {
    return getConnectionDuration(connection, now);
  }

  return Number(connection[column]) || 0;
}

// The sort is stable, so equal values keep the list's own order.
function getConnectionsForActiveTab(): MonitoredConnection[] {
  const source =
    activeTab === 'active'
      ? Array.from(activeConnections.values())
      : Array.from(closedConnections.values());
  const connections = sortConnections(source, activeTab);

  if (!connectionSort) {
    return connections;
  }

  const { column, descending } = connectionSort;
  const now = Date.now();
  const direction = descending ? -1 : 1;

  return connections.sort(
    (a, b) =>
      direction * (getSortValue(a, column, now) - getSortValue(b, column, now)),
  );
}

// A column sorts first the way it is read most: the shortest time, the most traffic.
function sortBy(column: ConnectionSortColumn) {
  const shown = getShownSort();
  connectionSort =
    shown?.column === column
      ? { column, descending: !shown.descending }
      : { column, descending: column !== 'time' };
  redrawForAction();
}

function normalizeSearchValue(value: string): string {
  return value.toLowerCase().replace(/\s+/g, ' ').trim();
}

function getSearchValues(connection: MonitoredConnection): string[] {
  const target = getTargetCellParts(connection);

  return [
    connection.id,
    target.primary,
    getNetwork(connection),
    getRoute(connection)?.label || '',
    formatConnectionDuration(connection),
    formatBytes(connection.download),
    formatBytes(connection.upload),
    getSource(connection).search,
  ].filter(Boolean);
}

function matchesConnectionFilters(
  connection: MonitoredConnection,
  normalizedSearch: string,
): boolean {
  if (
    selectedDeviceFilter !== ALL_FILTER_VALUE &&
    getSource(connection).key !== selectedDeviceFilter
  ) {
    return false;
  }

  if (
    selectedRouteFilter !== ALL_FILTER_VALUE &&
    getRoute(connection)?.tag !== selectedRouteFilter
  ) {
    return false;
  }

  if (!normalizedSearch) {
    return true;
  }

  return getSearchValues(connection).some((value) =>
    normalizeSearchValue(value).includes(normalizedSearch),
  );
}

function getVisibleConnections(): MonitoredConnection[] {
  const normalizedSearch = normalizeSearchValue(searchQuery);

  return getConnectionsForActiveTab().filter((connection) =>
    matchesConnectionFilters(connection, normalizedSearch),
  );
}

function filterConnections(
  connections: Map<string, MonitoredConnection>,
): MonitoredConnection[] {
  const normalizedSearch = normalizeSearchValue(searchQuery);

  return Array.from(connections.values()).filter((connection) =>
    matchesConnectionFilters(connection, normalizedSearch),
  );
}

function hasConnectionFilters(): boolean {
  return (
    selectedDeviceFilter !== ALL_FILTER_VALUE ||
    selectedRouteFilter !== ALL_FILTER_VALUE ||
    normalizeSearchValue(searchQuery) !== ''
  );
}

function moveConnectionToClosed(connection: MonitoredConnection, now: number) {
  closedConnections.set(connection.id, {
    ...connection,
    closedAt: now,
    lastSeenAt: now,
  });
}

function trimClosedConnections() {
  const sorted = sortConnections(
    Array.from(closedConnections.values()),
    'closed',
  );

  sorted.slice(CLOSED_CONNECTION_LIMIT).forEach((connection) => {
    closedConnections.delete(connection.id);
  });
}

function isMonitoringPaused() {
  return monitoringPaused || selectionHeld;
}

function applyConnectionsPayload(payload: ClashConnectionsPayload) {
  if (isMonitoringPaused()) {
    pendingConnectionsPayload = payload;
    return;
  }

  const mountId = monitoringMountId;
  const now = Date.now();
  const incomingIds = new Set<string>();
  const rawConnections = Array.isArray(payload.connections)
    ? payload.connections
    : [];

  rawConnections.forEach((rawConnection) => {
    const id = normalizeString(rawConnection.id);
    if (!id) {
      return;
    }

    incomingIds.add(id);
    closedConnections.delete(id);
    activeConnections.set(id, {
      ...rawConnection,
      id,
      lastSeenAt: now,
    });
  });

  Array.from(activeConnections.entries()).forEach(([id, connection]) => {
    if (!incomingIds.has(id)) {
      activeConnections.delete(id);
      moveConnectionToClosed(connection, now);
    }
  });

  trimClosedConnections();
  loading = false;
  failed = false;

  if (monitoringMounted && mountId === monitoringMountId) {
    renderControls();
    renderConnections();
  }
}

function setTab(tab: MonitoringTabId) {
  if (activeTab === tab) {
    return;
  }

  activeTab = tab;
  redrawForAction();
}

function getKnownSources(): ConnectionSource[] {
  const sources = new Map<string, ConnectionSource>();

  [activeConnections, closedConnections].forEach((connections) =>
    connections.forEach((connection) => {
      const source = getSource(connection);
      if (source.key && !sources.has(source.key)) {
        sources.set(source.key, source);
      }
    }),
  );

  return Array.from(sources.values()).sort(compareSources);
}

// Direct first, then the sections in the order the Sections tab lists them, then the rest.
function compareRoutes(a: ConnectionRoute, b: ConnectionRoute) {
  const rank = ({ tag }: ConnectionRoute) => {
    if (tag === DIRECT_ROUTE_TAG) {
      return -1;
    }

    const index = sectionTags.indexOf(tag);
    return index < 0 ? sectionTags.length : index;
  };

  return (
    rank(a) - rank(b) ||
    a.label.localeCompare(b.label, undefined, { numeric: true })
  );
}

function getKnownRoutes(): ConnectionRoute[] {
  const routes = new Map<string, ConnectionRoute>();

  [activeConnections, closedConnections].forEach((connections) =>
    connections.forEach((connection) => {
      const route = getRoute(connection);
      if (route) {
        routes.set(route.tag, route);
      }
    }),
  );

  return Array.from(routes.values()).sort(compareRoutes);
}

// A filter left on a value no connection has any more goes back to all.
function renderFilterOptions(
  id: string,
  allLabel: string,
  options: Array<{ value: string; label: string }>,
  selected: string,
): string {
  const value = options.some((option) => option.value === selected)
    ? selected
    : ALL_FILTER_VALUE;
  const select = document.getElementById(id) as HTMLSelectElement | null;

  if (!select) {
    return value;
  }

  const signature = JSON.stringify(options);
  if (signature !== filterSignatures[id]) {
    filterSignatures[id] = signature;
    select.replaceChildren(
      E('option', { value: ALL_FILTER_VALUE }, allLabel),
      ...options.map((option) =>
        E('option', { value: option.value }, option.label),
      ),
    );
  }

  select.value = value;
  return value;
}

function renderFilters() {
  selectedDeviceFilter = renderFilterOptions(
    'monitoring-device-filter',
    _('All devices'),
    getKnownSources().map((source) => ({
      value: source.key,
      label: sourceLabel(source.name, source.detail),
    })),
    selectedDeviceFilter,
  );
  selectedRouteFilter = renderFilterOptions(
    'monitoring-route-filter',
    _('All routes'),
    getKnownRoutes().map(({ tag, label }) => ({ value: tag, label })),
    selectedRouteFilter,
  );
}

function renderTab(
  tab: HTMLElement | null,
  label: string,
  count: number,
  active: boolean,
) {
  if (!tab) {
    return;
  }

  tab.className = active ? 'cbi-tab' : 'cbi-tab-disabled';
  tab.replaceChildren(
    E('a', { href: '#' }, [
      label,
      ' ',
      E('span', { class: 'fkp_monitoring-page__tab-count' }, String(count)),
    ]),
  );
}

function renderControls() {
  const closeAllButton = document.getElementById(
    'monitoring-close-all',
  ) as HTMLButtonElement | null;
  const autoRefreshInput = document.getElementById(
    'monitoring-auto-refresh',
  ) as HTMLInputElement | null;

  renderFilters();

  const filteredActive = filterConnections(activeConnections);

  renderTab(
    document.getElementById('monitoring-tab-active'),
    _('Active'),
    filteredActive.length,
    activeTab === 'active',
  );
  renderTab(
    document.getElementById('monitoring-tab-closed'),
    _('Closed'),
    filterConnections(closedConnections).length,
    activeTab === 'closed',
  );

  // With a filter set, the button closes what the Active count counts.
  if (closeAllButton) {
    const filtered = hasConnectionFilters();
    closeAllButton.textContent = filtered
      ? _('Close matching')
      : _('Close all');
    closeAllButton.title = filtered
      ? _('Close the connections that match the filters')
      : _('Close all connections');
    closeAllButton.disabled = closingAll || filteredActive.length === 0;
  }

  if (autoRefreshInput) {
    autoRefreshInput.checked = !monitoringPaused;
  }

  // The switch speaks for itself when it is off.
  const pauseNote = document.getElementById('monitoring-pause-note');
  if (pauseNote) {
    pauseNote.hidden = !selectionHeld || monitoringPaused;
  }

  const searchIcon = document.querySelector(
    '.fkp_monitoring-page__search-icon',
  );
  if (searchIcon && searchIcon.childNodes.length === 0) {
    searchIcon.replaceChildren(renderSearchIcon24());
  }
}

function toListItem(connection: MonitoredConnection): ConnectionListItem {
  const source = getSource(connection);
  const route = getRoute(connection);

  return {
    id: connection.id,
    host: getTargetCellParts(connection).primary,
    sourceName: source.name,
    sourceDetail: source.detail,
    system: source.kind === 'system',
    route: route?.label || '',
    direct: route?.tag === DIRECT_ROUTE_TAG,
    network: getNetwork(connection),
    time: formatConnectionDuration(connection),
    download: formatBytes(connection.download),
    upload: formatBytes(connection.upload),
    closing: closingConnectionIds.has(connection.id),
  };
}

function isTextSelectionInsideList(): boolean {
  const list = document.getElementById('monitoring-connections');
  const selection = window.getSelection?.();
  if (!list || !selection || selection.isCollapsed) {
    return false;
  }

  return (
    list.contains(selection.anchorNode) || list.contains(selection.focusNode)
  );
}

// A redraw takes a selection away, so one the user did not ask for waits until it is gone.
function renderConnections(options: { force?: boolean } = {}) {
  const container = document.getElementById('monitoring-connections');
  if (!container) {
    return;
  }

  if (!options.force && isTextSelectionInsideList()) {
    return;
  }

  const closable = activeTab === 'active';
  const sort = getShownSort();

  if (loading) {
    container.replaceChildren(
      renderConnectionListState(_('Loading connections...'), {
        closable,
        sort,
        className: 'fkp_monitoring-page__state--loading',
      }),
    );
    return;
  }

  if (failed) {
    container.replaceChildren(
      renderConnectionListState(_('Connections are unavailable'), {
        closable,
        sort,
        className: 'fkp_monitoring-page__state--error',
      }),
    );
    return;
  }

  const visibleConnections = getVisibleConnections();

  if (visibleConnections.length === 0) {
    container.replaceChildren(
      renderConnectionListState(
        closable ? _('No active connections') : _('No closed connections'),
        { closable, sort },
      ),
    );
    return;
  }

  container.replaceChildren(
    renderConnectionList(visibleConnections.map(toListItem), {
      closable,
      sort,
    }),
  );
}

// The Auto refresh switch and a text selection pause the whole tab, counters and durations
// included, so it shows one moment.
function updatePause(change: { user?: boolean; selection?: boolean }) {
  const user = change.user ?? monitoringPaused;
  const selection = change.selection ?? selectionHeld;
  if (user === monitoringPaused && selection === selectionHeld) {
    return;
  }

  const wasPaused = isMonitoringPaused();
  monitoringPaused = user;
  selectionHeld = selection;
  renderControls();

  const paused = isMonitoringPaused();
  if (paused === wasPaused) {
    return;
  }

  monitoringPausedAt = paused ? Date.now() : null;

  if (!paused) {
    const payload = pendingConnectionsPayload;
    pendingConnectionsPayload = null;

    if (payload) {
      applyConnectionsPayload(payload);
      return;
    }

    if (connectionsPoll.active) {
      connectionsPoll.now();
    }
  }

  renderConnections();
}

function holdForSelection() {
  updatePause({ selection: isTextSelectionInsideList() });
}

// Switching tab, device, search or sort replaces the list, so it is drawn at once.
function redrawForAction() {
  renderControls();
  renderConnections({ force: true });
  holdForSelection();
}

function getSelectionValueElements(selection: Selection): HTMLElement[] {
  const root = document.getElementById('monitoring-status');
  if (!root) {
    return [];
  }

  return Array.from(
    root.querySelectorAll<HTMLElement>(
      '.fkp_monitoring-page__value[data-copy-value]',
    ),
  ).filter((element) => {
    for (let index = 0; index < selection.rangeCount; index += 1) {
      try {
        if (selection.getRangeAt(index).intersectsNode(element)) {
          return true;
        }
      } catch (_error) {
        return false;
      }
    }

    return false;
  });
}

function handleMonitoringValueCopy(event: ClipboardEvent) {
  const selection = window.getSelection?.();
  if (!selection || selection.isCollapsed) {
    return;
  }

  const valueElements = getSelectionValueElements(selection);
  if (valueElements.length !== 1) {
    return;
  }

  const valueElement = valueElements[0];
  const fullText =
    valueElement.getAttribute('data-copy-value') ||
    valueElement.textContent ||
    '';
  const selectedText = selection.toString();

  if (!shouldCopyFullMonitoringValue(valueElement, selectedText, fullText)) {
    return;
  }

  event.clipboardData?.setData('text/plain', fullText);
  event.preventDefault();
}

async function closeConnection(connectionId: string) {
  if (!connectionId || closingConnectionIds.has(connectionId)) {
    return;
  }

  closingConnectionIds.add(connectionId);
  renderConnections();

  try {
    const response =
      await CustomLokiMethods.closeClashApiConnection(connectionId);

    if (!response.success) {
      showToast(_('Failed to close connection'), 'error');
      return;
    }

    const now = Date.now();
    const connection = activeConnections.get(connectionId);
    if (connection) {
      activeConnections.delete(connectionId);
      moveConnectionToClosed(connection, now);
      trimClosedConnections();
      pendingConnectionsPayload = null;
      renderControls();
    }
  } catch (error) {
    logger.error('[MONITORING]', 'closeConnection: failed', error);
    showToast(_('Failed to close connection'), 'error');
  } finally {
    closingConnectionIds.delete(connectionId);
    renderConnections();
  }
}

async function closeAllConnections() {
  if (activeConnections.size === 0 || closingAll) {
    return;
  }

  if (hasConnectionFilters()) {
    await closeMatchingConnections();
    return;
  }

  closingAll = true;
  renderControls();

  try {
    const response = await CustomLokiMethods.closeAllClashApiConnections();

    if (!response.success) {
      showToast(_('Failed to close connections'), 'error');
      return;
    }

    const now = Date.now();
    activeConnections.forEach((connection) => {
      moveConnectionToClosed(connection, now);
    });
    activeConnections.clear();
    pendingConnectionsPayload = null;
    trimClosedConnections();
  } catch (error) {
    logger.error('[MONITORING]', 'closeAllConnections: failed', error);
    showToast(_('Failed to close connections'), 'error');
  } finally {
    closingAll = false;
    renderControls();
    renderConnections();
  }
}

async function closeMatchingConnections() {
  const ids = filterConnections(activeConnections).map(({ id }) => id);
  if (ids.length === 0) {
    return;
  }

  closingAll = true;
  ids.forEach((id) => closingConnectionIds.add(id));
  renderControls();
  renderConnections();

  try {
    const { closed, failed } = await closeConnections(ids, (id) =>
      CustomLokiMethods.closeClashApiConnection(id),
    );

    const now = Date.now();
    closed.forEach((id) => {
      const connection = activeConnections.get(id);
      if (connection) {
        activeConnections.delete(id);
        moveConnectionToClosed(connection, now);
      }
    });
    if (closed.length) {
      pendingConnectionsPayload = null;
      trimClosedConnections();
    }
    if (failed.length) {
      showToast(_('Failed to close connections'), 'error');
    }
  } finally {
    ids.forEach((id) => closingConnectionIds.delete(id));
    closingAll = false;
    renderControls();
    renderConnections();
  }
}

function bindControls() {
  const activeTabItem = document.getElementById('monitoring-tab-active');
  const closedTabItem = document.getElementById('monitoring-tab-closed');
  const deviceFilter = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;
  const routeFilter = document.getElementById(
    'monitoring-route-filter',
  ) as HTMLSelectElement | null;
  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  const closeAllButton = document.getElementById('monitoring-close-all');
  const autoRefreshInput = document.getElementById(
    'monitoring-auto-refresh',
  ) as HTMLInputElement | null;
  const connectionsContainer = document.getElementById(
    'monitoring-connections',
  );

  // The tab is a link to nowhere, as LuCI's own are, so the page stays put.
  if (activeTabItem) {
    activeTabItem.onclick = (event) => {
      event.preventDefault();
      setTab('active');
    };
  }

  if (closedTabItem) {
    closedTabItem.onclick = (event) => {
      event.preventDefault();
      setTab('closed');
    };
  }

  if (closeAllButton) {
    closeAllButton.onclick = () => {
      void closeAllConnections();
    };
  }

  if (autoRefreshInput) {
    autoRefreshInput.onchange = () => {
      updatePause({ user: !autoRefreshInput.checked });
    };
  }

  if (deviceFilter) {
    deviceFilter.onchange = () => {
      selectedDeviceFilter = deviceFilter.value;
      redrawForAction();
    };
  }

  if (routeFilter) {
    routeFilter.onchange = () => {
      selectedRouteFilter = routeFilter.value;
      redrawForAction();
    };
  }

  if (searchInput) {
    searchInput.oninput = () => {
      searchQuery = searchInput.value;
      redrawForAction();
    };
  }

  if (connectionsContainer) {
    connectionsContainer.onclick = (event) => {
      const target = event.target as HTMLElement | null;
      const button = target?.closest(
        '.fkp_monitoring-page__row-action',
      ) as HTMLButtonElement | null;
      const sortButton = target?.closest(
        '.fkp_monitoring-page__sort',
      ) as HTMLButtonElement | null;

      if (button?.value) {
        void closeConnection(button.value);
      } else if (sortButton?.value) {
        sortBy(sortButton.value as ConnectionSortColumn);
      }
    };
  }
}

async function loadLocalDeviceNames() {
  try {
    localDeviceNames = (await loadLocalDevices()).names;
  } catch (error) {
    logger.warn('[MONITORING]', 'loadLocalDeviceNames: failed', error);
    localDeviceNames = {};
  } finally {
    renderControls();
    renderConnections();
  }
}

async function loadRouteDisplayNames() {
  try {
    buildRouteDisplayNames(await CustomLokiMethods.getConfigSections());
  } catch (error) {
    logger.warn('[MONITORING]', 'loadRouteDisplayNames: failed', error);
    buildRouteDisplayNames([]);
  } finally {
    renderControls();
    renderConnections();
  }
}

function reportPollFailure() {
  consecutivePollFailures += 1;
  failed = true;
  loading = false;
  renderConnections();
}

async function pollConnectionsSnapshot() {
  if (!monitoringMounted || isMonitoringPaused()) {
    return;
  }

  const mountId = monitoringMountId;
  const startedAt = Date.now();

  try {
    const response = await CustomLokiMethods.getClashApiConnections();

    lastConnectionsPollDurationMs = Date.now() - startedAt;

    if (
      !monitoringMounted ||
      mountId !== monitoringMountId ||
      !connectionsPoll.active
    ) {
      return;
    }

    if (!response.success) {
      reportPollFailure();
      return;
    }

    consecutivePollFailures = 0;
    applyConnectionsPayload(normalizeConnectionsPayload(response.data));
  } catch (error) {
    if (
      !monitoringMounted ||
      mountId !== monitoringMountId ||
      !connectionsPoll.active
    ) {
      return;
    }

    logger.error('[MONITORING]', 'connections polling failed', error);
    reportPollFailure();
  }
}

// A stopped core answers nothing, so the poll slows down while it keeps failing.
function connectionsPollDelay() {
  if (consecutivePollFailures > 0) {
    return Math.min(
      CONNECTIONS_RPC_POLL_INTERVAL_MS * 2 ** consecutivePollFailures,
      CONNECTIONS_RPC_POLL_BACKOFF_MAX_MS,
    );
  }

  return pollDelayForDuration(
    CONNECTIONS_RPC_POLL_INTERVAL_MS,
    lastConnectionsPollDurationMs,
    CONNECTIONS_POLL_DUTY_MAX_MS,
  );
}

const connectionsPoll = createPollChain(
  pollConnectionsSnapshot,
  connectionsPollDelay,
);

function startConnectionsPolling() {
  connectionsPoll.start(0);
}

function stopConnectionsPolling() {
  connectionsPoll.stop();
  consecutivePollFailures = 0;

  if (connectionsSocketGraceTimer) {
    clearTimeout(connectionsSocketGraceTimer);
    connectionsSocketGraceTimer = null;
  }
}

async function connectToConnectionsSocket(updatesId: number) {
  const mountId = monitoringMountId;
  // Without the secret the socket is refused, and the poll covers for it.
  const clashApiSecret = await getClashApiSecret().catch(() => '');

  if (
    !monitoringMounted ||
    mountId !== monitoringMountId ||
    updatesId !== connectionsUpdatesId
  ) {
    return;
  }

  connectionsSocketUrl = getClashSocketUrl('/connections', clashApiSecret);

  socket.subscribe(
    connectionsSocketUrl,
    (msg) => {
      if (updatesId !== connectionsUpdatesId) {
        return;
      }

      // The socket is delivering again, so the poll that covered for it stops.
      stopConnectionsPolling();

      try {
        applyConnectionsPayload(JSON.parse(msg) as ClashConnectionsPayload);
      } catch (error) {
        logger.error('[MONITORING]', 'connections socket parse failed', error);
      }
    },
    (_err) => {
      if (
        !monitoringMounted ||
        mountId !== monitoringMountId ||
        updatesId !== connectionsUpdatesId
      ) {
        return;
      }

      // The socket manager retries with a growing delay, so the poll only covers the gap; what the
      // table shows stays.
      startConnectionsPolling();
    },
  );
}

function startConnectionsUpdates() {
  if (canUseDirectClashApi()) {
    const updatesId = ++connectionsUpdatesId;
    void connectToConnectionsSocket(updatesId);
    connectionsSocketGraceTimer = setTimeout(() => {
      connectionsSocketGraceTimer = null;
      startConnectionsPolling();
    }, CONNECTIONS_SOCKET_GRACE_MS);
    return;
  }

  startConnectionsPolling();
}

function stopConnectionsUpdates() {
  connectionsUpdatesId += 1;
  stopConnectionsPolling();

  if (connectionsSocketUrl) {
    socket.disconnect(connectionsSocketUrl);
    connectionsSocketUrl = '';
  }
}

function resetMonitoringState() {
  activeTab = 'active';
  selectedDeviceFilter = ALL_FILTER_VALUE;
  selectedRouteFilter = ALL_FILTER_VALUE;
  searchQuery = '';
  connectionSort = null;
  filterSignatures = {};
  loading = true;
  failed = false;
  closingAll = false;
  monitoringPaused = false;
  selectionHeld = false;
  monitoringPausedAt = null;
  consecutivePollFailures = 0;
  lastConnectionsPollDurationMs = 0;
  pendingConnectionsPayload = null;
  activeConnections.clear();
  closedConnections.clear();
  closingConnectionIds.clear();

  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  if (searchInput) {
    searchInput.value = '';
  }
}

// Asks the Clash API directly: an answer is what says there is something to show.
function onPageMount() {
  onPageUnmount();

  monitoringMounted = true;
  monitoringMountId += 1;

  resetClashApiTransport();
  resetMonitoringState();
  bindControls();
  renderControls();
  renderConnections();
  startConnectionsUpdates();

  void loadLocalDeviceNames();
  void loadRouteDisplayNames();

  document.addEventListener('selectionchange', holdForSelection);
  document.addEventListener('copy', handleMonitoringValueCopy);

  renderTimer = setInterval(() => {
    if (isMonitoringPaused() || !isDocumentVisible()) {
      return;
    }

    renderConnections();
  }, RENDER_INTERVAL_MS);
}

function onPageUnmount() {
  monitoringMounted = false;
  monitoringMountId += 1;

  if (renderTimer) {
    clearInterval(renderTimer);
    renderTimer = null;
  }

  stopConnectionsUpdates();

  document.removeEventListener('selectionchange', holdForSelection);
  document.removeEventListener('copy', handleMonitoringValueCopy);
}

const monitoringLifecycle = createTabLifecycle({
  shown: () =>
    isDocumentVisible() && store.get().tabService.current === 'monitoring',
  start: onPageMount,
  stop: onPageUnmount,
});

function registerLifecycleListeners() {
  if (monitoringLifecycleRegistered) {
    return;
  }

  monitoringLifecycleRegistered = true;

  store.subscribe(
    (next: StoreType, prev: StoreType, diff: Partial<StoreType>) => {
      if (
        diff.tabService &&
        next.tabService.current !== prev.tabService.current
      ) {
        monitoringLifecycle.update();
      }
    },
  );
  document.addEventListener('visibilitychange', () =>
    monitoringLifecycle.update(),
  );
}

export async function initController(): Promise<void> {
  if (monitoringControllerInitialized) {
    return;
  }

  monitoringControllerInitialized = true;

  onMount('monitoring-status').then(() => {
    registerLifecycleListeners();
    monitoringLifecycle.update();
  });
}
