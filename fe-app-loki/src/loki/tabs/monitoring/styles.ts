// language=CSS
import { LOKI_UCI_PACKAGE as LOKI_CBI_PREFIX } from '../../../constants';

export const styles = `
/* The tab is one DummyValue inside the theme's flex row; a block mount node gives the page's
width: 100% something to resolve against. */
#cbi-${LOKI_CBI_PREFIX}-monitoring-_mount_node {
    display: block;
    margin: 16px 0 22px;
    padding: 0;
}

#cbi-${LOKI_CBI_PREFIX}-monitoring > h3 {
    display: none;
}

/* Follows the page's width, not the window's: a theme sidebar leaves far less. */
.fkp_monitoring-page {
    --fkp-monitoring-row-action-size: 24px;
    --fkp-monitoring-divider-color: rgba(127, 127, 127, 0.22);
    --fkp-monitoring-soft-bg: rgba(127, 127, 127, 0.08);
    --fkp-monitoring-soft-bg-hover: rgba(127, 127, 127, 0.14);
    --fkp-monitoring-danger-color: var(--error-color-medium, #d32f2f);

    container-type: inline-size;
    width: 100%;
    min-width: 0;
}

.fkp_monitoring-page__panel {
    margin-top: 0;
    border: 0;
    border-radius: 0;
    padding: 0;
    background: transparent;
    box-sizing: border-box;
    width: 100%;
    min-width: 0;
}

.fkp_monitoring-page__controls {
    display: grid;
    grid-template-columns: minmax(0, 1fr) max-content;
    grid-template-areas: 'filters actions';
    align-items: center;
    gap: 12px 16px;
    margin-bottom: 12px;
}

/* The free end of the tab bar, so showing it moves nothing; it is no tab, so the theme's tab
rules leave it alone. */
.fkp_monitoring-page__pause-note {
    flex: 1 1 0;
    min-width: 0;
    align-self: center;
    margin-left: 8px;
    text-align: right;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-color-medium, #888);
}

.fkp_monitoring-page__pause-note[hidden] {
    display: none;
}

.fkp_monitoring-page__tab-count {
    color: var(--text-color-medium, #888);
    font-variant-numeric: tabular-nums;
}

/* A theme may replace the select with its own dropdown, so columns fill in order rather than by
named children. */
.fkp_monitoring-page__filters {
    grid-area: filters;
    display: grid;
    grid-template-columns: minmax(0, 220px) minmax(0, 220px) minmax(0, 320px);
    align-items: center;
    gap: 8px;
    min-width: 0;
}

.fkp_monitoring-page .fkp_monitoring-page__filters > * {
    width: 100%;
    min-width: 0;
    margin: 0;
    box-sizing: border-box;
}

.fkp_monitoring-page__search {
    position: relative;
    display: flex;
    align-items: center;
}

.fkp_monitoring-page__search-icon {
    position: absolute;
    left: 8px;
    width: 16px;
    height: 16px;
    color: var(--text-color-medium);
    pointer-events: none;
}

.fkp_monitoring-page__search-icon svg {
    width: 16px;
    height: 16px;
    display: block;
}

.fkp_monitoring-page .fkp_monitoring-page__search-input {
    width: 100%;
    padding-left: 30px !important;
    margin: 0 !important;
    box-sizing: border-box;
}

.fkp_monitoring-page__actions {
    grid-area: actions;
    display: flex;
    align-items: center;
    gap: 16px;
}

.fkp_monitoring-page__checkbox {
    display: inline-flex;
    align-items: center;
    gap: 0.4em;
    margin: 0;
    white-space: nowrap;
    cursor: pointer;
    user-select: none;
}

.fkp_monitoring-page__checkbox input {
    margin: 0;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__action {
    margin: 0;
    white-space: nowrap;
}

.fkp_monitoring-page__body {
    width: 100%;
    min-width: 0;
}

/* Every row is a subgrid, so columns size like a table's; only host, source and route give way
when the width runs short. */
.fkp_monitoring-page__list {
    --fkp-monitoring-sort-arrow-size: 12px;
    --fkp-monitoring-sort-arrow-gap: 2px;
    --fkp-monitoring-columns:
        minmax(8em, auto)
        minmax(6em, auto)
        minmax(5.5em, auto)
        minmax(max-content, auto)
        minmax(max-content, auto)
        minmax(max-content, auto)
        minmax(max-content, auto);

    display: grid;
    grid-template-columns: var(--fkp-monitoring-columns);
    column-gap: 12px;
    font-size: 13px;
}

.fkp_monitoring-page__list--closable {
    grid-template-columns: var(--fkp-monitoring-columns) max-content;
}

.fkp_monitoring-page__row {
    grid-column: 1 / -1;
    display: grid;
    grid-template-columns: subgrid;
    align-items: center;
    min-height: 36px;
    padding: 0 6px;
    border-bottom: 1px solid var(--fkp-monitoring-divider-color);
    box-sizing: border-box;
}

.fkp_monitoring-page__row:last-child {
    border-bottom: 0;
}

.fkp_monitoring-page__row--head {
    min-height: 30px;
    border-bottom-color: rgba(127, 127, 127, 0.32);
    color: var(--text-color-medium);
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
}

/* A selection inside the list holds the monitoring, so only the values can be selected. */
.fkp_monitoring-page__row--head,
.fkp_monitoring-page__row--state {
    user-select: none;
}

.fkp_monitoring-page .fkp_monitoring-page__sort {
    display: inline-flex;
    align-items: center;
    gap: var(--fkp-monitoring-sort-arrow-gap);
    max-width: 100%;
    min-height: 0;
    margin: 0;
    padding: 0;
    border: 0;
    border-radius: 0;
    background: none;
    box-shadow: none;
    color: inherit;
    font: inherit;
    letter-spacing: inherit;
    text-transform: inherit;
    cursor: pointer;
}

.fkp_monitoring-page .fkp_monitoring-page__sort:hover,
.fkp_monitoring-page__cell[aria-sort] .fkp_monitoring-page__sort {
    color: var(--text-color-high);
}

.fkp_monitoring-page__sort svg {
    width: var(--fkp-monitoring-sort-arrow-size);
    height: var(--fkp-monitoring-sort-arrow-size);
    flex: 0 0 auto;
    visibility: hidden;
}

.fkp_monitoring-page__cell[aria-sort] .fkp_monitoring-page__sort svg {
    visibility: visible;
}

.fkp_monitoring-page__cell[aria-sort='descending'] .fkp_monitoring-page__sort svg {
    transform: rotate(180deg);
}

.fkp_monitoring-page__row:not(.fkp_monitoring-page__row--head):not(.fkp_monitoring-page__row--state):hover {
    background: var(--fkp-monitoring-soft-bg);
}

.fkp_monitoring-page__row--closing {
    opacity: 0.55;
}

.fkp_monitoring-page__cell {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
}

.fkp_monitoring-page__cell--time,
.fkp_monitoring-page__cell--download,
.fkp_monitoring-page__cell--upload {
    text-align: right;
    font-variant-numeric: tabular-nums;
}

.fkp_monitoring-page__cell--action {
    display: flex;
    justify-content: center;
    overflow: visible;
}

.fkp_monitoring-page__value {
    display: block;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    line-height: 1.3;
    color: var(--text-color-high);
    user-select: text;
}

.fkp_monitoring-page__tag {
    display: inline-block;
    max-width: 100%;
    box-sizing: border-box;
    padding: 2px 6px;
    border-radius: 4px;
    background: rgba(128, 128, 128, 0.15);
    font-size: 11px;
    font-weight: 500;
    vertical-align: middle;
}

.fkp_monitoring-page__tag--builtin {
    background: transparent;
    box-shadow: inset 0 0 0 1px rgba(128, 128, 128, 0.35);
    color: var(--text-color-medium, #bbb);
}

.fkp_monitoring-page__network {
    color: var(--text-color-medium, #bbb);
    text-transform: lowercase;
}

.fkp_monitoring-page__muted {
    color: var(--text-color-medium, #bbb);
}

/* The sort arrow sits right of its heading, so the values end where the heading's text does. */
.fkp_monitoring-page__cell--time .fkp_monitoring-page__value,
.fkp_monitoring-page__cell--download .fkp_monitoring-page__value,
.fkp_monitoring-page__cell--upload .fkp_monitoring-page__value {
    padding-right: calc(var(--fkp-monitoring-sort-arrow-size) + var(--fkp-monitoring-sort-arrow-gap));
    color: var(--text-color-medium, #bbb);
}

.fkp_monitoring-page .btn.fkp_monitoring-page__row-action {
    width: var(--fkp-monitoring-row-action-size);
    height: var(--fkp-monitoring-row-action-size);
    min-width: var(--fkp-monitoring-row-action-size);
    min-height: var(--fkp-monitoring-row-action-size);
    padding: 0;
    box-sizing: border-box;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
    margin: 0;
    border: 0 !important;
    border-radius: 999px;
    background: transparent !important;
    color: var(--fkp-monitoring-danger-color) !important;
    box-shadow: none;
    cursor: pointer;
}

.fkp_monitoring-page__row-action svg {
    width: 14px;
    height: 14px;
    display: block;
    flex: 0 0 auto;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__row-action:hover:not(:disabled) {
    background: var(--fkp-monitoring-soft-bg-hover) !important;
    color: var(--fkp-monitoring-danger-color) !important;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__row-action:disabled {
    opacity: 0.45;
    cursor: wait;
}

.fkp_monitoring-page__state {
    grid-column: 1 / -1;
    min-height: 90px;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-color-medium);
    text-align: center;
    white-space: normal;
}

.fkp_monitoring-page__state--error {
    color: var(--error-color-medium, #d32f2f);
}

/* Three filters beside the actions leave each too narrow to read. */
@container (max-width: 899px) {
    .fkp_monitoring-page__controls {
        grid-template-columns: minmax(0, 1fr);
        grid-template-areas:
            'filters'
            'actions';
    }

    .fkp_monitoring-page__filters {
        grid-template-columns: minmax(0, 2fr) minmax(0, 2fr) minmax(0, 3fr);
    }

    .fkp_monitoring-page__actions {
        justify-self: end;
    }
}

/* Below this width every connection becomes a three-line card. */
@container (max-width: 639px) {
    .fkp_monitoring-page__list {
        display: block;
    }

    .fkp_monitoring-page__row {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        column-gap: 8px;
        row-gap: 2px;
        padding: 8px 0;
    }

    .fkp_monitoring-page__row--head {
        display: none;
    }

    .fkp_monitoring-page__row--state {
        display: block;
    }

    .fkp_monitoring-page__row:not(.fkp_monitoring-page__row--state):hover {
        background: none;
    }

    .fkp_monitoring-page__row:not(.fkp_monitoring-page__row--state)::before,
    .fkp_monitoring-page__row:not(.fkp_monitoring-page__row--state)::after {
        content: '';
        flex: 0 0 100%;
        height: 0;
    }

    .fkp_monitoring-page__row::before {
        order: 3;
    }

    .fkp_monitoring-page__row::after {
        order: 5;
    }

    .fkp_monitoring-page__cell {
        flex: 0 0 auto;
        max-width: 100%;
    }

    .fkp_monitoring-page__cell--host {
        order: 1;
        flex: 1 1 0;
        font-weight: 600;
    }

    .fkp_monitoring-page__cell--action {
        order: 2;
    }

    .fkp_monitoring-page__cell--source,
    .fkp_monitoring-page__cell--route,
    .fkp_monitoring-page__cell--network {
        order: 4;
    }

    .fkp_monitoring-page__cell--time,
    .fkp_monitoring-page__cell--download,
    .fkp_monitoring-page__cell--upload {
        order: 6;
        font-size: 12px;
    }

    .fkp_monitoring-page__cell--download {
        margin-left: auto;
    }

    .fkp_monitoring-page__cell--download::before {
        content: '\\2193';
        margin-right: 3px;
        color: var(--text-color-medium);
    }

    .fkp_monitoring-page__cell--upload::before {
        content: '\\2191';
        margin-right: 3px;
        color: var(--text-color-medium);
    }

    .fkp_monitoring-page__cell--time .fkp_monitoring-page__value,
    .fkp_monitoring-page__cell--download .fkp_monitoring-page__value,
    .fkp_monitoring-page__cell--upload .fkp_monitoring-page__value {
        padding-right: 0;
    }

    .fkp_monitoring-page__cell--download .fkp_monitoring-page__value,
    .fkp_monitoring-page__cell--upload .fkp_monitoring-page__value {
        display: inline;
    }
}

@container (max-width: 519px) {
    .fkp_monitoring-page__filters,
    .fkp_monitoring-page__actions {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 8px;
        justify-self: stretch;
    }

    .fkp_monitoring-page__search {
        grid-column: 1 / -1;
    }
}
`;
