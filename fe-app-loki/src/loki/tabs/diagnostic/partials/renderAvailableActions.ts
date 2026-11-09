import { renderButton } from '../../../../partials';
import {
  renderCirclePlayIcon24,
  renderCircleStopIcon24,
  renderPauseIcon24,
  renderPlayIcon24,
  renderRotateCcwIcon24,
} from '../../../../icons';
import { insertIf } from '../../../../helpers/insertIf';
import { E } from '../../../../helpers/element';

interface ActionProps {
  loading: boolean;
  visible: boolean;
  disabled: boolean;
  onClick: () => void;
}

// While an operation runs its own button is the progress indicator; an apply keeps the service
// running, so it is not called a restart.
interface RestartActionProps extends ActionProps {
  mode: 'restart' | 'apply';
}

function restartActionText(restart: RestartActionProps) {
  if (!restart.loading) {
    return _('Restart');
  }

  return restart.mode === 'apply' ? _('Applying...') : _('Restarting...');
}

interface IRenderAvailableActionsProps {
  restart: RestartActionProps;
  start: ActionProps;
  stop: ActionProps;
  enable: ActionProps;
  disable: ActionProps;
}

export function renderAvailableActions({
  restart,
  start,
  stop,
  enable,
  disable,
}: IRenderAvailableActionsProps) {
  return E('div', { class: 'fkp_diagnostic-page__controls__actions' }, [
    E('b', {}, _('Available actions')),
    ...insertIf(restart.visible, [
      renderButton({
        classNames: ['cbi-button-apply'],
        onClick: restart.onClick,
        icon: renderRotateCcwIcon24,
        text: restartActionText(restart),
        loading: restart.loading,
        disabled: restart.disabled,
      }),
    ]),
    ...insertIf(stop.visible, [
      renderButton({
        classNames: ['cbi-button-remove'],
        onClick: stop.onClick,
        icon: renderCircleStopIcon24,
        text: stop.loading ? _('Stopping...') : _('Stop'),
        loading: stop.loading,
        disabled: stop.disabled,
      }),
    ]),
    ...insertIf(start.visible, [
      renderButton({
        classNames: ['cbi-button-save'],
        onClick: start.onClick,
        icon: renderCirclePlayIcon24,
        text: start.loading ? _('Starting...') : _('Start'),
        loading: start.loading,
        disabled: start.disabled,
      }),
    ]),
    ...insertIf(disable.visible, [
      renderButton({
        classNames: ['cbi-button-remove'],
        onClick: disable.onClick,
        icon: renderPauseIcon24,
        text: _('Disable autostart'),
        loading: disable.loading,
        disabled: disable.disabled,
      }),
    ]),
    ...insertIf(enable.visible, [
      renderButton({
        classNames: ['cbi-button-save'],
        onClick: enable.onClick,
        icon: renderPlayIcon24,
        text: _('Enable autostart'),
        loading: enable.loading,
        disabled: enable.disabled,
      }),
    ]),
  ]);
}
