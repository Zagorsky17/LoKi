import { DragDropContext, Draggable, Droppable, DropResult } from '@hello-pangea/dnd';
import cx from 'clsx';
import * as React from 'react';
import { useTranslation } from 'react-i18next';

import { Menu, Trash2, X } from '~/components/shared/FeatherIcons';
import Modal from '~/components/shared/Modal';
import Switch from '~/components/shared/SwitchThemed';
import { ConnectionColumn, ConnectionSettings, SourceMapItem } from '~/modules/connections/utils';

import s from './ConnectionSettingsModal.module.scss';

type Props = {
  isOpen: boolean;
  onRequestClose: () => void;
  settings: ConnectionSettings;
  updateSettings: (patch: Partial<ConnectionSettings>) => void;
  visibleColumns: ConnectionColumn[];
  availableColumns: ConnectionColumn[];
  addColumn: (id: string) => void;
  removeColumn: (id: string) => void;
  reorderColumns: (fromIndex: number, toIndex: number) => void;
  resetColumns: () => void;
  sourceMap: SourceMapItem[];
  setSourceMap: (updater: React.SetStateAction<SourceMapItem[]>) => void;
};

function ToggleRow({
  label,
  hint,
  checked,
  onChange,
}: {
  label: string;
  hint: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <div className={s.row}>
      <span className={s.rowLabel}>{label}</span>
      <span className={s.rowHint}>{hint}</span>
      <div className={s.rowControl}>
        <Switch checked={checked} onChange={onChange} />
      </div>
    </div>
  );
}

export default function ConnectionSettingsModal({
  isOpen,
  onRequestClose,
  settings,
  updateSettings,
  visibleColumns,
  availableColumns,
  addColumn,
  removeColumn,
  reorderColumns,
  resetColumns,
  sourceMap,
  setSourceMap,
}: Props) {
  const { t } = useTranslation();

  const setSource = (key: keyof SourceMapItem, index: number, value: string) => {
    setSourceMap((prev) => prev.map((item, i) => (i === index ? { ...item, [key]: value } : item)));
  };

  const onDragEnd = (result: DropResult) => {
    if (!result.destination) return;
    reorderColumns(result.source.index, result.destination.index);
  };

  return (
    <Modal
      isOpen={isOpen}
      onRequestClose={onRequestClose}
      title={t('conn_settings')}
      className={s.modal}
    >
      <div className={s.header}>
        <span className={s.headerTitle}>{t('conn_settings')}</span>
        <button
          type="button"
          className={s.headerClose}
          onClick={onRequestClose}
          aria-label={t('close_all_confirm_no')}
        >
          <X size={15} />
        </button>
      </div>

      <div className={s.body}>
        <div className={s.row}>
          <span className={s.rowLabel}>{t('hide_conn_regex')}</span>
          <div className={s.rowControl}>
            <input
              type="text"
              className={s.textInput}
              value={settings.hideRegex}
              placeholder="direct|dns-out"
              onChange={(e) => updateSettings({ hideRegex: e.target.value })}
            />
          </div>
        </div>

        <ToggleRow
          label={t('hide_conn')}
          hint={t('hide_conn_hint')}
          checked={settings.hideEnabled}
          onChange={(value) => updateSettings({ hideEnabled: value })}
        />
        <ToggleRow
          label={t('full_chain')}
          hint={t('full_chain_hint')}
          checked={settings.fullChain}
          onChange={(value) => updateSettings({ fullChain: value })}
        />

        <section className={s.section}>
          <span className={s.sectionTitle}>{t('custom_columns')}</span>
          <div className={s.columnsGrid}>
            <div className={s.columnsPane}>
              <div className={s.paneHead}>
                <span>{t('columns_enabled')}</span>
                <span className={s.paneCount}>{visibleColumns.length}</span>
              </div>
              <DragDropContext onDragEnd={onDragEnd}>
                <Droppable droppableId="enabled-columns">
                  {(provided) => (
                    <div
                      className={s.paneBodyFilled}
                      ref={provided.innerRef}
                      {...provided.droppableProps}
                    >
                      {visibleColumns.map((column, index) => (
                        <Draggable key={column.id} draggableId={column.id} index={index}>
                          {(dragProvided, snapshot) => (
                            <div
                              ref={dragProvided.innerRef}
                              {...dragProvided.draggableProps}
                              className={cx(s.enabledItem, {
                                [s.enabledItemDragging]: snapshot.isDragging,
                              })}
                            >
                              <span
                                {...dragProvided.dragHandleProps}
                                className={s.dragHandle}
                                title={t('drag_to_reorder')}
                              >
                                <Menu size={13} />
                              </span>
                              <span className={s.itemLabel}>{t(column.labelKey)}</span>
                              <button
                                type="button"
                                className={s.removeBtn}
                                onClick={() => removeColumn(column.id)}
                                title={t('remove')}
                              >
                                <X size={13} />
                              </button>
                            </div>
                          )}
                        </Draggable>
                      ))}
                      {provided.placeholder}
                    </div>
                  )}
                </Droppable>
              </DragDropContext>
            </div>

            <div className={s.columnsPane}>
              <div className={s.paneHead}>
                <span>{t('columns_available')}</span>
                <span className={s.paneCount}>{availableColumns.length}</span>
              </div>
              <div className={s.paneBodyOutlined}>
                {availableColumns.map((column) => (
                  <button
                    key={column.id}
                    type="button"
                    className={s.availableItem}
                    onClick={() => addColumn(column.id)}
                  >
                    <span className={s.itemLabel}>{t(column.labelKey)}</span>
                    <span className={s.addSign} aria-hidden>
                      ＋
                    </span>
                  </button>
                ))}
                {availableColumns.length === 0 ? (
                  <span className={s.paneEmpty}>{t('columns_all_enabled')}</span>
                ) : null}
              </div>
            </div>
          </div>
        </section>

        <section className={s.section}>
          <span className={s.sectionTitle}>{t('client_tag')}</span>
          <span className={s.sectionHint}>{t('sourceip_tip')}</span>
          <div className={s.tagList}>
            {sourceMap.map((item, index) => (
              <div key={index} className={s.tagRow}>
                <input
                  type="text"
                  className={s.textInput}
                  value={item.reg}
                  placeholder={t('c_source')}
                  onChange={(e) => setSource('reg', index, e.target.value)}
                />
                <input
                  type="text"
                  className={s.textInput}
                  value={item.name}
                  placeholder={t('device_name')}
                  onChange={(e) => setSource('name', index, e.target.value)}
                />
                <button
                  type="button"
                  className={s.removeBtn}
                  onClick={() => setSourceMap((prev) => prev.filter((_, i) => i !== index))}
                  title={t('delete')}
                >
                  <Trash2 size={13} />
                </button>
              </div>
            ))}
          </div>
          <button
            type="button"
            className={s.ghostBtn}
            onClick={() => setSourceMap((prev) => [...prev, { reg: '', name: '' }])}
          >
            {t('add_tag')}
          </button>
        </section>
      </div>

      <div className={s.footer}>
        <button type="button" className={s.ghostBtn} onClick={resetColumns}>
          {t('reset_default_columns')}
        </button>
        <button type="button" className={s.primaryBtn} onClick={onRequestClose}>
          {t('done')}
        </button>
      </div>
    </Modal>
  );
}
