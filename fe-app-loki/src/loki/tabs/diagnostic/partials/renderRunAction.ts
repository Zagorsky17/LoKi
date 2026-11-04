import { renderButton } from '../../../../partials';
import { renderFileTextIcon24, renderSearchIcon24 } from '../../../../icons';
import { E } from '../../../../helpers/element';

interface RunActionButton {
  loading: boolean;
  disabled?: boolean;
  click: () => void;
}

interface IRenderDiagnosticRunActionProps extends RunActionButton {
  report: RunActionButton | null;
}

// The run, and under it the report of what the run found, once there is one.
export function renderRunAction({
  loading,
  disabled,
  click,
  report,
}: IRenderDiagnosticRunActionProps) {
  return E('div', { class: 'fkp_diagnostic-page__run_check_wrapper' }, [
    renderButton({
      text: _('Run Diagnostic'),
      onClick: click,
      icon: renderSearchIcon24,
      loading,
      disabled,
      classNames: ['cbi-button-apply'],
    }),
    ...(report
      ? [
          renderButton({
            text: _('Get report'),
            onClick: report.click,
            icon: renderFileTextIcon24,
            loading: report.loading,
            disabled: report.disabled,
          }),
        ]
      : []),
  ]);
}
