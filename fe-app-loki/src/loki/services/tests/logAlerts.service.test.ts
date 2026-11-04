import { describe, expect, it } from 'vitest';

import { LogAlerts } from '../logAlerts.service';
import { LogNotificationDeduper } from '../logNotificationDeduper.service';

const REFUSED =
  "Mon Oct 19 16:03:10 2026 user.err loki: [error] Section 'proxy' holds WARP tunnel 'Tunnel #1'";
const NOT_APPLIED =
  'Mon Oct 19 16:03:10 2026 user.warn loki: [warn] Configuration not applied; LoKi keeps running the previous one';
const APPLYING =
  'Mon Oct 19 16:04:47 2026 user.info loki: [info] Applying configuration';
const APPLIED =
  'Mon Oct 19 16:04:50 2026 user.info loki: [info] Configuration applied';
const REFUSED_AGAIN =
  "Mon Oct 19 16:04:47 2026 user.err loki: [error] Section 'proxy' holds WARP tunnel 'Tunnel #1'";

type FakeAlert = { message: string; open: boolean };

function openPage() {
  const raised: FakeAlert[] = [];
  const alerts = new LogAlerts((notification) => {
    const alert = { message: notification.message, open: true };
    raised.push(alert);
    return {
      get isConnected() {
        return alert.open;
      },
      classList: { contains: () => false },
      remove: () => {
        alert.open = false;
      },
    } as unknown as HTMLElement;
  }, new LogNotificationDeduper(null));
  const open = () =>
    raised.filter((alert) => alert.open).map(({ message }) => message);
  return { alerts, open };
}

describe('the alerts the log raises', () => {
  it('stay open until the next action begins, and go to the page LuCI loads next', () => {
    const { alerts, open } = openPage();
    alerts.read(REFUSED);
    alerts.read(NOT_APPLIED);

    expect(open()).toEqual(["Section 'proxy' holds WARP tunnel 'Tunnel #1'"]);
    expect(alerts.openLines()).toEqual([REFUSED]);
  });

  it('close when the next action begins, which raises its own', () => {
    const { alerts, open } = openPage();
    alerts.read(REFUSED);
    alerts.read(APPLYING);
    alerts.read(APPLIED);

    expect(open()).toEqual([]);
    expect(alerts.openLines()).toEqual([]);

    alerts.read(REFUSED_AGAIN);
    expect(alerts.openLines()).toEqual([REFUSED_AGAIN]);
  });

  it('close at the opening of every Loki action, and at nothing else', () => {
    const openings = [
      'user.info loki: [info] Starting LoKi',
      'user.info loki: [info] Stopping LoKi',
      'user.info loki[42]: [info] Applying configuration',
      "user.info loki: [info] Reapplying configuration: interface 'wan' came up",
    ];
    for (const opening of openings) {
      const { alerts } = openPage();
      alerts.read(REFUSED);
      alerts.read(opening);
      expect(alerts.openLines(), opening).toEqual([]);
    }

    const others = [
      APPLIED,
      'user.info loki: [info] LoKi is already running',
      'user.warn loki: [warn] Applying configuration',
      'daemon.info sing-box[7]: [info] Starting LoKi',
    ];
    for (const other of others) {
      const { alerts } = openPage();
      alerts.read(REFUSED);
      alerts.read(other);
      expect(alerts.openLines(), other).toEqual([REFUSED]);
    }
  });

  it('handed on by a reload close when the next page reads the action that followed them', () => {
    const { alerts, open } = openPage();
    alerts.reopen([REFUSED]);
    expect(open()).toEqual(["Section 'proxy' holds WARP tunnel 'Tunnel #1'"]);

    alerts.read(APPLYING);
    expect(open()).toEqual([]);
    expect(alerts.openLines()).toEqual([]);
  });
});
