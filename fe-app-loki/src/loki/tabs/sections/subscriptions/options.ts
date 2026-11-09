import {
  childItemInputValue,
  isExistingChildItem,
  parentSectionIdForItem,
} from '../../../cbi/childItems';
import {
  keepUnavailableSectionChoice,
  validateSectionChoice,
  refreshOptionChoices,
} from '../../../cbi/choices';
import { updateDynamicListItemLabel } from '../../../cbi/listItems';
import { required } from '../../../cbi/required';
import { message } from '../../../../validators/messages';
import { showChildItemSettingsModal } from '../../../cbi/modal';
import { addCascadeOptions } from '../cascade';
import { subscriptionDownloadTargetChoices } from '../references';
import {
  addServerFilterOptions,
  subscriptionServerFilterDescriptions,
} from '../serverFilters';
import {
  validateOptionalSingBoxDuration,
  validateRequiredSingBoxDuration,
} from '../../../../validators/validateSingBoxDuration';
import { showSubscriptionHeadersModal } from './headers';
import {
  applyRemoteSubscriptionUrlSettings,
  cleanupRemoteSubscriptionUrlSettings,
  configuredSubscriptionTags,
  defaultSubscriptionUrlSettings,
  isRemoteSubscriptionSource,
  currentOptionValue,
  listedSubscriptionTag,
  loadDefaultSubscriptionHeaders,
  nextSubscriptionTag,
  optionMapValue,
  subscriptionUrlSettingsKeys,
  validateSubscriptionUrlEntry,
} from './model';
import { showSubscriptionOverrideModal } from './overrides';

// Fetch settings show only while the address field holds a URL.
const REMOTE_SOURCE = /^https?:\/\//;

export function addSubscriptionUrlItemOptions(
  itemSection: CBISection,
  options: Partial<ChildItemDialogContext> = {},
) {
  const parentSectionForItem =
    typeof options.parentSectionId === 'function'
      ? options.parentSectionId
      : parentSectionIdForItem;

  let o = itemSection.option(form.Value, 'tag', _('Subscription name'));
  o.validate = required(function (_itemId, value) {
    const normalized = value.trim();
    if (normalized.includes('/')) {
      return message.slashInName();
    }
    const sectionId = parentSectionForItem(_itemId);
    const ownerId =
      typeof options.ownerId === 'function' ? options.ownerId() : '';
    const inputValue =
      typeof options.itemValue === 'function' ? options.itemValue() : '';
    return configuredSubscriptionTags(sectionId, options.listOption!, [
      ownerId === sectionId ? '' : ownerId,
      inputValue,
    ]).includes(normalized)
      ? message.nameTaken()
      : true;
  });

  o = itemSection.option(
    form.Value,
    'url',
    _('Subscription URL'),
    _('A URL, or the absolute path of a file on the router'),
  );
  // A subscription URL carries the token of its account.
  o.password = true;
  o.validate = required((itemId, value) =>
    validateSubscriptionUrlEntry(itemId, value.trim()),
  );

  addCascadeOptions(
    itemSection,
    parentSectionForItem,
    _('Connect to every server of this subscription through another section'),
  );

  o = itemSection.option(
    form.Flag,
    'subscription_update_enabled',
    _('Subscription auto update'),
    _('Update the subscription automatically at a set interval'),
  );
  o.depends('url', REMOTE_SOURCE);
  o.default = '1';
  o.rmempty = false;

  o = itemSection.option(
    form.Value,
    'subscription_update_interval',
    _('Update interval'),
    _('For example 30m, 12h or 1d'),
  );
  o.depends({ url: REMOTE_SOURCE, subscription_update_enabled: '1' });
  o.placeholder = '1h';
  o.validate = function (itemId: string, value: unknown) {
    return currentOptionValue(this, itemId, 'subscription_update_enabled') ===
      '1'
      ? validateRequiredSingBoxDuration(value)
      : validateOptionalSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Flag,
    'download_via_proxy_enabled',
    _('Request through a section'),
    _('Download the subscription through another section instead of directly'),
  );
  o.depends('url', REMOTE_SOURCE);
  o.default = '0';
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    'download_via_proxy_section',
    _('Request through'),
  );
  o.depends({ url: REMOTE_SOURCE, download_via_proxy_enabled: '1' });
  o.load = function (itemId: string) {
    const sectionId = parentSectionForItem(itemId);
    refreshOptionChoices(this, subscriptionDownloadTargetChoices(sectionId));
    const value =
      optionMapValue(this, itemId, 'download_via_proxy_section') || '';
    keepUnavailableSectionChoice(this, value);
    return value;
  };
  o.validate = function (itemId: string, value: unknown) {
    return currentOptionValue(this, itemId, 'download_via_proxy_enabled') ===
      '1'
      ? validateSectionChoice(this, value, parentSectionForItem(itemId))
      : true;
  };

  o = itemSection.option(
    form.Button,
    '_subscription_headers',
    _('Headers'),
    _('Change the HTTP headers of the request'),
  );
  o.depends('url', REMOTE_SOURCE);
  o.inputtitle = _('Edit');
  o.inputstyle = 'edit';
  o.onclick = function () {
    return showSubscriptionHeadersModal(itemSection.map, 'settings');
  };

  o = itemSection.option(
    form.Flag,
    'show_dashboard_metadata',
    _('Show metadata'),
    _('Show the metadata block on the dashboard'),
  );
  o.depends('url', REMOTE_SOURCE);
  o.default = '1';
  o.rmempty = false;

  o = itemSection.option(
    form.Button,
    '_subscription_override',
    _('Server parameters'),
    _('Change the parameters of the servers this subscription adds'),
  );
  o.inputtitle = _('Edit');
  o.inputstyle = 'edit';
  o.onclick = function () {
    return showSubscriptionOverrideModal(itemSection.map, 'settings');
  };

  addServerFilterOptions(itemSection, parentSectionForItem, {
    ownerId: options.ownerId,
    modeLabel: _('Server filter'),
    modeDescription: _('Which servers to import'),
    modes: [
      { value: 'all', label: _('All servers') },
      { value: 'exclude', label: _('All except selected') },
      { value: 'include', label: _('Only selected') },
    ],
    ...subscriptionServerFilterDescriptions(),
  });
}

export function showSubscriptionUrlSettingsModal(
  sectionId: string,
  itemValue: unknown,
  option: CBIOption,
  _widget: CBIWidget,
  itemNode: Element | null,
) {
  const value = `${itemValue ?? ''}`;
  const tag = listedSubscriptionTag(sectionId, value);
  const storedRemote =
    isExistingChildItem(sectionId, value, 'subscription_url') &&
    isRemoteSubscriptionSource(
      childItemInputValue(sectionId, value, 'subscription_url', 'url'),
    );
  // A remote subscription keeps its headers, none included; others are offered the defaults, carried
  // only once the address becomes a URL. The dialog opens without them too.
  return loadDefaultSubscriptionHeaders()
    .catch(() => [] as string[])
    .then((headers: string[]) =>
      showChildItemSettingsModal(sectionId, itemValue, option, {
        typeName: 'subscription_url',
        valueOption: 'url',
        keys: ['url', ...subscriptionUrlSettingsKeys()],
        itemNode,
        defaults: (inputValue: string) =>
          Object.assign(
            defaultSubscriptionUrlSettings(
              storedRemote ? [] : headers,
              nextSubscriptionTag(sectionId, option),
            ),
            { url: inputValue },
          ),
        addOptions: addSubscriptionUrlItemOptions,
        title: () =>
          tag ? _('Subscription: %s').format(tag) : _('Subscription settings'),
        afterSave: (
          itemId: string,
          _inputValue: string,
          settings: ChildSettings,
          existing: boolean,
        ) => {
          if (existing && !isRemoteSubscriptionSource(settings.url)) {
            cleanupRemoteSubscriptionUrlSettings(itemId);
          } else if (existing && !storedRemote) {
            applyRemoteSubscriptionUrlSettings(itemId, settings);
          }
          updateDynamicListItemLabel(itemNode, `${settings.tag || ''}`.trim());
        },
      }),
    );
}
