import {
  LokiLogNotification,
  getLokiLogNotification,
  LogNotificationDeduper,
  opensLokiAction,
} from './logNotificationDeduper.service';

// LuCI dismisses an alert by fading it out and then removing it.
function isOpen(node: HTMLElement) {
  return node.isConnected && !node.classList.contains('fade-out');
}

// An error reports a step of its action, so the next action to begin closes the alerts.
export class LogAlerts {
  private readonly show: (notification: LokiLogNotification) => HTMLElement;
  private readonly deduper: LogNotificationDeduper;
  private shown: { line: string; node: HTMLElement }[] = [];

  constructor(
    show: (notification: LokiLogNotification) => HTMLElement,
    deduper = new LogNotificationDeduper(),
  ) {
    this.show = show;
    this.deduper = deduper;
  }

  // The alerts the page LuCI just reloaded still had open.
  reopen(lines: string[]) {
    lines.forEach((line) => this.raise(line));
  }

  read(line: string) {
    if (opensLokiAction(line)) {
      this.shown.splice(0).forEach(({ node }) => node.remove());
    }
    if (this.deduper.shouldNotify(line)) {
      this.raise(line);
    }
  }

  openLines() {
    return this.shown
      .filter(({ node }) => isOpen(node))
      .map(({ line }) => line);
  }

  private raise(line: string) {
    const notification = getLokiLogNotification(line);
    if (notification) {
      this.shown.push({ line, node: this.show(notification) });
    }
  }
}
