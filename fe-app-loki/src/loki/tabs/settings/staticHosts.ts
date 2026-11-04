import { analyzeStaticHosts } from '../../../validators/validateStaticHosts';
import { configureTextareaOption } from '../../cbi/annotatedTextarea';
import {
  SINGLE_FIELD_MODAL_CLASS,
  ensureSingleFieldModalStyles,
} from '../../cbi/modal';
import { E } from '../../../helpers/element';

// One address per line with its names, in both families.
export const STATIC_HOSTS_PLACEHOLDER = [
  '192.168.1.10 nas.local',
  '10.0.0.5 printer.local printer',
  '2606:4700::1111 dns.example',
].join('\n');

function configureStaticHostsTextarea(option: CBIOption) {
  option.rows = 16;
  option.wrap = 'soft';
  option.rmempty = true;
  option.placeholder = STATIC_HOSTS_PLACEHOLDER;
  option.validate = function (_section_id: string, value: string) {
    const analysis = analyzeStaticHosts(`${value || ''}`);
    return analysis.valid ? true : analysis.message;
  };
}

function showStaticHostsModal(textareaNode: HTMLTextAreaElement) {
  const data = { settings: { static_hosts_text: textareaNode.value || '' } };
  const map = new form.JSONMap(data);
  const itemSection = map.section(form.NamedSection, 'settings');
  itemSection.anonymous = true;
  itemSection.addremove = false;

  const records = itemSection.option(
    form.TextValue,
    'static_hosts_text',
    _('Static DNS records'),
  );
  configureStaticHostsTextarea(records);
  configureTextareaOption(records, analyzeStaticHosts);

  const save = () =>
    map
      .parse()
      .then(() => {
        const value =
          `${map.data.get(map.config, 'settings')!.static_hosts_text || ''}`
            .replace(/\r/g, '')
            .trim();

        textareaNode.value = value ? `${value}\n` : '';
        textareaNode.dispatchEvent(new Event('change', { bubbles: true }));
        ui.hideModal();
      })
      .catch(() => {});

  ensureSingleFieldModalStyles();

  return map.render().then((nodes) => {
    nodes.classList.add(SINGLE_FIELD_MODAL_CLASS);
    ui.showModal(
      _('Static DNS records'),
      [
        nodes,
        E('div', { class: 'button-row' }, [
          E(
            'button',
            {
              class: 'btn cbi-button',
              type: 'button',
              click: () => ui.hideModal(),
            },
            _('Close'),
          ),
          ' ',
          E(
            'button',
            {
              class: 'btn cbi-button cbi-button-positive important',
              type: 'button',
              click: save,
            },
            _('Save'),
          ),
        ]),
      ],
      'cbi-modal',
    );

    const editor = nodes.querySelector('textarea');
    if (editor) {
      editor.focus();
    }
  });
}

export function createStaticHostsOption(section: CBISection) {
  const option = section.option(
    form.TextValue,
    'static_hosts_text',
    _('Static DNS records'),
    _('Fixed addresses for domains in the hosts format'),
  );
  configureStaticHostsTextarea(option);

  const renderTextarea = option.renderWidget;
  option.renderWidget = function (
    section_id: string,
    option_index: string,
    cfgvalue: unknown,
  ) {
    const widget = renderTextarea.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    ) as HTMLElement;
    const textareaNode = widget.querySelector
      ? widget.querySelector('textarea')
      : null;

    if (!textareaNode) {
      return widget;
    }

    widget.style.display = 'none';

    return E('div', {}, [
      widget,
      E(
        'button',
        {
          class: 'btn cbi-button cbi-button-action',
          type: 'button',
          click: (event) => {
            event.preventDefault();
            showStaticHostsModal(textareaNode);
          },
        },
        _('Edit'),
      ),
    ]);
  };

  return option;
}
