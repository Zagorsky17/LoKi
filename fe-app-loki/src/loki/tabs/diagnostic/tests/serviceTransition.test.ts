import { describe, expect, it } from 'vitest';
import {
  getAutostartControlsPresentation,
  getServiceControlsPresentation,
  getServiceOperation,
  hasLocalMutatingServiceActionLoading,
  isServiceBusy,
  serviceActionFailureMessage,
  shouldDisableDiagnosticRunAction,
} from '../serviceTransition';
import type { ServiceOperation } from '../serviceTransition';

function actions({
  restart = false,
  start = false,
  stop = false,
  enable = false,
  disable = false,
} = {}) {
  return {
    restart: { loading: restart },
    start: { loading: start },
    stop: { loading: stop },
    enable: { loading: enable },
    disable: { loading: disable },
  };
}

function controls(running: boolean, operation: ServiceOperation | null) {
  return getServiceControlsPresentation({ running, operation });
}

describe('service operation resolution', () => {
  it('takes the runtime answer when it has one', () => {
    expect(
      getServiceOperation({ busy: 'apply', localPending: 'restart' }),
    ).toBe('apply');
  });

  it('falls back to a click the runtime has not seen yet', () => {
    expect(getServiceOperation({ busy: null, localPending: 'stop' })).toBe(
      'stop',
    );
  });

  it('reports no operation when nothing is in flight', () => {
    expect(getServiceOperation({ busy: null, localPending: null })).toBeNull();
    expect(isServiceBusy(null)).toBe(false);
    expect(isServiceBusy('start')).toBe(true);
  });
});

describe('service control presentation', () => {
  it('offers restart and stop while the service is idle and running', () => {
    const state = controls(true, null);

    expect(state.restart).toMatchObject({ visible: true, disabled: false });
    expect(state.stop).toMatchObject({ visible: true, disabled: false });
    expect(state.start.visible).toBe(false);
  });

  it('offers only start while the service is idle and stopped', () => {
    const state = controls(false, null);

    expect(state.start).toMatchObject({ visible: true, disabled: false });
    expect(state.restart.visible).toBe(false);
    expect(state.stop.visible).toBe(false);
  });

  it('disables only the button whose operation is running', () => {
    const state = controls(false, 'start');

    expect(state.start).toMatchObject({
      visible: true,
      loading: true,
      disabled: true,
    });
    expect(state.restart.visible).toBe(false);
  });

  it.each([
    ['start' as const, false],
    ['restart' as const, true],
    ['apply' as const, true],
  ])('shows only the operating button during %s', (operation, running) => {
    const state = controls(running, operation);
    const visible = Object.entries(state)
      .filter(([, control]) => control.visible)
      .map(([name]) => name);

    expect(visible).toEqual([operation === 'start' ? 'start' : 'restart']);
  });

  it('does not reveal stop when running turns true mid-start', () => {
    expect(controls(true, 'start').stop.visible).toBe(false);
  });

  it.each([
    ['start' as const, false],
    ['restart' as const, true],
    ['apply' as const, true],
  ])('offers no stop while %s runs', (operation, running) => {
    expect(controls(running, operation).stop.visible).toBe(false);
  });

  it('offers stop for a service that is up and idle', () => {
    expect(controls(true, null).stop).toMatchObject({
      visible: true,
      disabled: false,
    });
    expect(controls(false, null).stop.visible).toBe(false);
  });

  it('shows the stop button as its own progress while stopping', () => {
    const state = controls(true, 'stop');

    expect(state.stop).toMatchObject({
      visible: true,
      loading: true,
      disabled: true,
    });
    expect(state.restart.visible).toBe(false);
    expect(state.start.visible).toBe(false);
  });

  it('labels an apply as an apply rather than a restart', () => {
    expect(controls(true, 'apply').restart.mode).toBe('apply');
    expect(controls(true, 'restart').restart.mode).toBe('restart');
    expect(controls(true, null).restart.mode).toBe('restart');
  });

  it('keeps the restart control in place for the whole apply', () => {
    const state = controls(true, 'apply');

    expect(state.restart).toMatchObject({
      visible: true,
      loading: true,
      disabled: true,
    });
    expect(state.start.visible).toBe(false);
  });

  it('shows restart while the service is running even when autostart is off', () => {
    expect(controls(true, null).restart.visible).toBe(true);
  });

  it('offers no lifecycle control while the installer runs, whatever the service does', () => {
    for (const running of [true, false]) {
      const state = controls(running, 'install');
      expect([
        state.restart.visible,
        state.start.visible,
        state.stop.visible,
      ]).toEqual([false, false, false]);
    }
    expect(
      shouldDisableDiagnosticRunAction({
        capabilitiesLoaded: true,
        operation: 'install',
      }),
    ).toBe(true);
  });
});

describe('a state that has not arrived yet', () => {
  it('offers nothing at all', () => {
    const state = getServiceControlsPresentation({
      running: false,
      operation: null,
      known: false,
    });

    expect(state.restart.visible).toBe(false);
    expect(state.start.visible).toBe(false);
    expect(state.stop.visible).toBe(false);
  });

  it('offers no autostart control either', () => {
    const state = getAutostartControlsPresentation({
      enabled: false,
      enableLoading: false,
      disableLoading: false,
      known: false,
    });

    expect(state.enable.visible).toBe(false);
    expect(state.disable.visible).toBe(false);
  });

  it('offers the normal row once it has', () => {
    const state = getServiceControlsPresentation({
      running: true,
      operation: null,
      known: true,
    });

    expect(state.restart.visible).toBe(true);
    expect(state.stop.visible).toBe(true);
  });
});

describe('autostart controls', () => {
  it('shows exactly one of the two and never gates it on service state', () => {
    const enabled = getAutostartControlsPresentation({
      enabled: true,
      enableLoading: false,
      disableLoading: false,
    });

    expect(enabled.disable).toMatchObject({ visible: true, disabled: false });
    expect(enabled.enable.visible).toBe(false);

    const disabled = getAutostartControlsPresentation({
      enabled: false,
      enableLoading: false,
      disableLoading: false,
    });

    expect(disabled.enable).toMatchObject({ visible: true, disabled: false });
    expect(disabled.disable.visible).toBe(false);
  });

  it('blocks only its own double submit', () => {
    const state = getAutostartControlsPresentation({
      enabled: false,
      enableLoading: true,
      disableLoading: false,
    });

    expect(state.enable).toMatchObject({ loading: true, disabled: true });
  });
});

describe('diagnostics run action', () => {
  it('runs while the service is stopped, which is when it is most useful', () => {
    expect(
      shouldDisableDiagnosticRunAction({
        capabilitiesLoaded: true,
        operation: null,
      }),
    ).toBe(false);
  });

  it('waits until the page knows what to check', () => {
    expect(
      shouldDisableDiagnosticRunAction({
        capabilitiesLoaded: false,
        operation: null,
      }),
    ).toBe(true);
  });

  it('waits out a start, stop or apply, which would replace what it checks', () => {
    for (const operation of ['start', 'stop', 'restart', 'apply'] as const) {
      expect(
        shouldDisableDiagnosticRunAction({
          capabilitiesLoaded: true,
          operation,
        }),
      ).toBe(true);
    }
  });
});

describe('polling and service actions', () => {
  it('detects only local button loading as local mutation', () => {
    expect(hasLocalMutatingServiceActionLoading(actions())).toBe(false);
    expect(hasLocalMutatingServiceActionLoading(actions({ stop: true }))).toBe(
      true,
    );
    expect(
      hasLocalMutatingServiceActionLoading(actions({ disable: true })),
    ).toBe(true);
  });

  it('names the action a request could not start', () => {
    expect(serviceActionFailureMessage('start')).toBe(
      'Failed to start the service',
    );
    expect(serviceActionFailureMessage('stop')).toBe(
      'Failed to stop the service',
    );
    expect(serviceActionFailureMessage('restart')).toBe(
      'Failed to restart the service',
    );
    expect(serviceActionFailureMessage('something-else')).toBe(
      'Service action failed',
    );
  });
});
