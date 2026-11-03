// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import { E } from '../../../helpers/element';
import { showToast } from '../../../helpers/showToast';
import {
  renderCircleCheckIcon24,
  renderCircleStopIcon24,
  renderCircleXIcon24,
  renderCopyIcon24,
  renderDownloadIcon24,
  renderFileDownIcon24,
  renderFileTextIcon24,
  renderFileUpIcon24,
  renderLayersIcon24,
  renderLoaderCircleIcon24,
  renderSquareTerminalIcon24,
  renderTrashIcon24,
} from '../../../icons';
import { renderButton, renderModal } from '../../../partials';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { store } from '../../services/store.service';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import type { Forkop } from '../../types';
import {
  configImportApi,
  configText,
  downloadConfig,
  MAX_CONFIG_SIZE,
  refusalMessage,
  renderImportDialog,
} from './configFile';
import { installerApi } from './installerApi';
import {
  createInstallerRun,
  InstallerAfterRun,
  InstallerRunState,
} from './installerRun';
import { removedPackages, renderRemoveDialog } from './removeDialog';
import { pageRoot } from './render';
import { formatRunTime } from './runTime';
import { createTerminal } from './terminal';

let controllerInitialized = false;

// install.sh speaks Russian or English; the page asks in its own language.
function installerLanguage() {
  return document.documentElement.lang.toLowerCase().startsWith('ru')
    ? 'ru'
    : 'en';
}

function componentsTabShown() {
  return (
    store.get().tabService.current === 'components' ||
    isActiveLuciTab('components')
  );
}

function part<T extends HTMLElement>(root: HTMLElement, id: string) {
  return root.querySelector(`#${id}`) as T;
}

function statusOf(state: InstallerRunState): {
  tone: 'progress' | 'success' | 'error';
  icon: () => SVGSVGElement;
  text: string;
} {
  if (state.starting || state.running) {
    let text = _('in progress');
    if (state.lost) {
      text = _('no answer from the router');
    } else if (state.stopping) {
      text = _('stopping...');
    }
    return { tone: 'progress', icon: renderLoaderCircleIcon24, text };
  }
  if (state.exit === 0) {
    return { tone: 'success', icon: renderCircleCheckIcon24, text: _('done') };
  }
  return {
    tone: 'error',
    icon: renderCircleXIcon24,
    text: state.interrupted || state.stopping ? _('interrupted') : _('failed'),
  };
}

const AFTER_RUN_TEXTS: Record<InstallerAfterRun, () => string> = {
  reload: () => _('the page reloads'),
  leave: () => _('going to the LuCI home page'),
};

export function initController(): void {
  if (controllerInitialized || !pageRoot) {
    return;
  }
  controllerInitialized = true;
  const root = pageRoot;

  const terminal = createTerminal({
    label: _('Installer output'),
    onInput: (data) => void run.input(data),
    onInterrupt: () => void run.stop(),
  });
  const runStatus = E('span', { class: 'fkp_components-page__run-status' });
  const copyButton = E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button fkp_components-page__icon-button',
      title: _('Copy the output'),
      'aria-label': _('Copy the output'),
      click: () => copyToClipboard(terminal.text()),
    },
    [renderCopyIcon24()],
  );
  const stopButton = E(
    'button',
    {
      type: 'button',
      class:
        'btn cbi-button cbi-button-remove fkp_components-page__icon-button',
      title: _('Interrupt the installer'),
      'aria-label': _('Interrupt the installer'),
      click: () => void run.stop(),
    },
    [renderCircleStopIcon24()],
  ) as HTMLButtonElement;
  const logButton = E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button fkp_components-page__icon-button',
      title: _('Installer log'),
      'aria-label': _('Installer log'),
      click: () => void openLog(),
    },
    [renderFileTextIcon24()],
  ) as HTMLButtonElement;
  const runSide = E('div', { class: 'fkp_components-page__run-side' }, [
    runStatus,
    stopButton,
    logButton,
    copyButton,
  ]);
  part(root, 'components-run').append(
    E('div', { class: 'fkp_components-page__run-header' }, [
      E('div', { class: 'fkp_components-page__run-title' }, [
        renderSquareTerminalIcon24(),
        E('span', {}, _('Terminal')),
      ]),
      runSide,
    ]),
    terminal.element,
  );

  let runState: InstallerRunState | null = null;
  let runDrawn = '';

  function renderRun(state: InstallerRunState) {
    runSide.hidden = !state.id && !state.starting;
    stopButton.hidden = !state.running || !state.id;
    stopButton.disabled = state.stopping;
    logButton.hidden = !state.log;
    terminal.setInput(state.running && state.interactive);
    const live = state.starting || state.running;
    const at = live ? state.startedAt : state.finishedAt;
    const drawn = JSON.stringify([
      live,
      at,
      state.exit,
      state.interrupted,
      state.stopping,
      state.lost,
      state.after,
    ]);
    if (drawn === runDrawn) {
      return;
    }
    runDrawn = drawn;
    const status = statusOf(state);
    const after = state.after ? ` · ${AFTER_RUN_TEXTS[state.after]()}` : '';
    runStatus.className = `fkp_components-page__run-status fkp_components-page__run-status--${status.tone}`;
    runStatus.replaceChildren(
      ...(at === null
        ? []
        : [
            E(
              'span',
              { class: 'fkp_components-page__run-time' },
              formatRunTime(at),
            ),
          ]),
      status.icon(),
      E('span', {}, status.text + after),
    );
  }

  async function openLog() {
    logButton.disabled = true;
    try {
      const text = await installerApi.log();
      ui.showModal(_('Installer log'), renderModal(text, 'forkop-install-log'));
    } catch (error) {
      showToast(
        error instanceof Error ? error.message : String(error),
        'error',
      );
    } finally {
      logButton.disabled = false;
    }
  }

  // Redrawn only when they change: a button replaced between press and release loses the click.
  let actionsDrawn = '';

  function renderActions(state: InstallerRunState) {
    const operation = store.get().serviceState.data.forkopBusy;
    const live = state.starting || state.running;
    // a start, stop or apply in progress leaves install.sh nothing safe to stop
    const blocked = live || (operation !== null && operation !== 'install');
    const drawn = JSON.stringify([blocked, live && state.action]);
    if (drawn === actionsDrawn) {
      return;
    }
    actionsDrawn = drawn;
    const button = (
      action: Forkop.InstallerAction,
      icon: () => SVGSVGElement,
      text: string,
      classNames: string[],
      onClick: () => void,
    ) =>
      renderButton({
        classNames,
        icon,
        text,
        loading: live && state.action === action,
        disabled: blocked,
        onClick,
      });

    part(root, 'components-actions').replaceChildren(
      E('b', {}, _('Available actions')),
      button(
        'update',
        renderDownloadIcon24,
        _('Run the installer'),
        ['cbi-button-apply'],
        () => void run.start('update'),
      ),
      button('variant', renderLayersIcon24, _('Change the build'), [], () => {
        void run.start('variant').then(() => terminal.focus());
      }),
      button(
        'uninstall',
        renderTrashIcon24,
        _('Remove LoKi'),
        ['cbi-button-remove'],
        openRemoveDialog,
      ),
    );
  }

  function renderVersions() {
    const info = store.get().diagnosticsSystemInfo;
    const loaded = Boolean(info.loaded);
    part(root, 'components-forkop-version').replaceChildren(
      loaded ? info.forkop_version : '',
    );
    const core = part(root, 'components-core-version');
    core.replaceChildren(loaded ? info.sing_box_version : '');
    if (loaded && info.sing_box_variant) {
      core.append(
        E(
          'span',
          { class: 'fkp_components-page__badge' },
          info.sing_box_variant,
        ),
      );
    }
  }

  // A refusal carries its reason, which takes longer to read than a toast usually stays.
  const REFUSAL_TOAST_MS = 8000;
  // The theme styles file inputs over the hidden attribute.
  const configFileInput = E('input', {
    type: 'file',
    style: 'display: none',
  }) as HTMLInputElement;
  configFileInput.addEventListener('change', () => {
    const file = configFileInput.files?.[0];
    // the same file picked again must fire again
    configFileInput.value = '';
    if (file) {
      void uploadConfig(file);
    }
  });
  let configBusy: 'download' | 'upload' | null = null;
  let configDrawn = '';

  function renderConfig() {
    const live = Boolean(runState?.starting || runState?.running);
    const drawn = JSON.stringify([configBusy, live]);
    if (drawn === configDrawn) {
      return;
    }
    configDrawn = drawn;
    part(root, 'components-config').replaceChildren(
      E('b', {}, _('Configuration')),
      E('div', { class: 'fkp_components-page__config-buttons' }, [
        renderButton({
          icon: renderFileDownIcon24,
          text: _('Download'),
          loading: configBusy === 'download',
          onClick: () => void saveConfig(),
        }),
        renderButton({
          icon: renderFileUpIcon24,
          text: _('Upload'),
          loading: configBusy === 'upload',
          // install.sh may replace the configuration under the staged changes
          disabled: live,
          onClick: () => configFileInput.click(),
        }),
      ]),
      configFileInput,
    );
  }

  function setConfigBusy(busy: typeof configBusy) {
    configBusy = busy;
    renderConfig();
  }

  async function saveConfig() {
    setConfigBusy('download');
    try {
      await downloadConfig();
    } catch (error) {
      showToast(
        error instanceof Error ? error.message : String(error),
        'error',
      );
    } finally {
      setConfigBusy(null);
    }
  }

  async function stageConfig(text: string) {
    const staged = await configImportApi.stage(text).catch((error) => ({
      success: false as const,
      reason: 'staging',
      to: '',
      min: '',
      detail: error instanceof Error ? error.message : String(error),
    }));
    if (!staged.success) {
      ui.hideModal();
      showToast(refusalMessage(staged), 'error', REFUSAL_TOAST_MS);
      return;
    }
    // The forms show what they loaded; the staged configuration reaches them with the page.
    window.location.reload();
  }

  async function uploadConfig(file: File) {
    if (file.size > MAX_CONFIG_SIZE) {
      showToast(
        _('The file is over 1 MB, far larger than a LoKi configuration'),
        'error',
      );
      return;
    }
    setConfigBusy('upload');
    try {
      const text = configText(await file.text());
      const check = await configImportApi.check(text);
      if (!check.success) {
        showToast(refusalMessage(check), 'error', REFUSAL_TOAST_MS);
      } else if (!check.changed) {
        showToast(
          _('Nothing to upload: the file holds the current configuration'),
          'success',
        );
      } else {
        ui.showModal(
          _('Upload the configuration?'),
          renderImportDialog(file.name, check, () => stageConfig(text)),
        );
      }
    } catch (error) {
      showToast(
        error instanceof Error ? error.message : String(error),
        'error',
      );
    } finally {
      setConfigBusy(null);
    }
  }

  function openRemoveDialog() {
    ui.showModal(
      _('Remove LoKi?'),
      renderRemoveDialog(
        removedPackages(store.get().diagnosticsSystemInfo),
        (purge) => void run.start('uninstall', '', purge),
      ),
    );
  }

  const run = createInstallerRun({
    api: installerApi,
    terminal,
    lang: installerLanguage,
    onChange: (state) => {
      runState = state;
      renderRun(state);
      renderActions(state);
      renderConfig();
    },
    onStartFailed: (message) => showToast(message, 'error'),
    onAfterRun: (after) => {
      if (after === 'leave') {
        window.location.href = L.url('admin');
      } else {
        window.location.reload();
      }
    },
  });

  renderRun(run.state);
  renderActions(run.state);
  renderConfig();
  renderVersions();
  store.subscribeKey('diagnosticsSystemInfo', renderVersions);
  store.subscribeKey('tabService', () => {
    run.setShown(componentsTabShown());
    if (componentsTabShown()) {
      void ensureSystemInfo();
    }
  });
  // A run that began on another page or in a terminal shows up here as the feed reports it.
  store.subscribeKey('serviceState', (serviceState) => {
    if (serviceState.data.forkopBusy === 'install') {
      run.refresh();
    }
    renderActions(runState ?? run.state);
  });
  if (componentsTabShown()) {
    run.setShown(true);
    void ensureSystemInfo();
  } else if (store.get().serviceState.data.forkopBusy === 'install') {
    run.refresh();
  }
}
