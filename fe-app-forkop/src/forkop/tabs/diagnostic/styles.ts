// Modified for LoKi on 2026-11-01: keep browser traffic observations informational.
// language=CSS
import { FORKOP_UCI_PACKAGE as FORKOP_CBI_PREFIX } from '../../../constants';

export const styles = `

#cbi-${FORKOP_CBI_PREFIX}-diagnostic > h3 {
    display: none;
}

/* The tab is one DummyValue inside the theme's flex row; this makes the page take the column's
width. */
#cbi-${FORKOP_CBI_PREFIX}-diagnostic-_mount_node {
    display: block;
    container-type: inline-size;
}

/* The controls take what their buttons need, never less than the longest system information
row; the checks sit beside them at a reading width, so nothing a check reports moves the
controls. */
.fkp_diagnostic-page {
    display: grid;
    grid-template-columns: minmax(17rem, max-content) minmax(0, 38rem);
    grid-gap: 10px;
    align-items: start;
    width: 100%;
}

.fkp_diagnostic-page__controls {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    grid-row-gap: 10px;
}

.fkp_diagnostic-page__controls__actions {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;

    display: grid;
    grid-template-columns: auto;
    grid-row-gap: 10px;

}

.fkp_diagnostic-page__controls__actions > .fkp-partial-button {
    width: 100%;
    min-width: 0;
    margin-left: 0;
}

/* A definite zero width keeps the rows, which arrive one at a time, from resizing the column. */
.fkp_diagnostic-page__controls__system-info {
    width: 0;
    min-width: 100%;

    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;

    display: grid;
    grid-template-columns: auto;
    grid-row-gap: 10px;
}

.fkp_diagnostic-page__controls__system-info__row {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    grid-column-gap: 5px;
}

/* A version string has nowhere to break, so it may break anywhere. */
.fkp_diagnostic-page__controls__system-info__row > div {
    min-width: 0;
    overflow-wrap: anywhere;
}

.fkp_diagnostic-page__controls__system-info__badge {
    display: inline-block;
    margin-left: 0.4rem;
    padding: 0.1rem 0.35rem;
    border-radius: 0.25rem;
    color: var(--text-color-medium);
    background: var(--background-color-low);
    font-size: 0.72rem;
    line-height: 1.2;
    vertical-align: 0.08rem;
}

.fkp_diagnostic-page__results {
    display: grid;
    grid-template-columns: 1fr;
    grid-row-gap: 10px;
}

.fkp_diagnostic-page__run_check_wrapper {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    grid-row-gap: 10px;
}

.fkp_diagnostic-page__run_check_wrapper > .fkp-partial-button {
    width: 100%;
    min-width: 0;
    margin-left: 0;
}

.fkp_diagnostic-page__checks {
    display: grid;
    grid-template-columns: 1fr;
    grid-row-gap: 10px;
}

/* Below about 19rem of checks beside the controls, the two stack. */
@container (max-width: 599px) {
    .fkp_diagnostic-page {
        grid-template-columns: minmax(0, 1fr);
    }
}

.fkp_diagnostic_alert {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
}

.fkp_diagnostic_alert__header {
    display: grid;
    grid-template-columns: 24px minmax(0, 1fr) auto;
    grid-column-gap: 10px;
    align-items: center;
}

.fkp_diagnostic_alert__header--foldable {
    cursor: pointer;
}

/* The state icon and the chevron share the header's centre line. */
.fkp_diagnostic_alert__icon {
    display: flex;
}

.fkp_diagnostic-page .btn.fkp_diagnostic_alert__toggle {
    width: 22px;
    height: 22px;
    min-width: 22px;
    min-height: 22px;
    padding: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: transparent !important;
    border: none !important;
    box-shadow: none !important;
    color: inherit;
    opacity: 0.55;
}

.fkp_diagnostic-page .btn.fkp_diagnostic_alert__toggle:focus-visible {
    opacity: 1;
}

.fkp_diagnostic_alert__toggle svg {
    width: 16px;
    height: 16px;
    display: block;
    transition: transform 0.15s ease;
}

.fkp_diagnostic_alert__toggle--collapsed svg {
    transform: rotate(180deg);
}

.fkp_diagnostic_alert--loading {
    border: 2px var(--primary-color-high, dodgerblue) solid;
}

.fkp_diagnostic_alert--warning {
    border: 2px var(--warn-color-medium, orange) solid;
    color: var(--warn-color-medium, orange);
}

.fkp_diagnostic_alert--error {
    border: 2px var(--error-color-medium, red) solid;
    color: var(--error-color-medium, red);
}

.fkp_diagnostic_alert--success {
    border: 2px var(--success-color-medium, green) solid;
    color: var(--success-color-medium, green);
}

.fkp_diagnostic_alert__title {
    display: block;
}

.fkp_diagnostic_alert__summary {
    margin: 10px 0 0 34px;
}

.fkp_diagnostic_alert__summary__item {
    display: grid;
    grid-template-columns: 16px minmax(0, 1fr);
    grid-column-gap: 10px;
}

/* Key and value side by side while both fit, stacked otherwise; each row decides by its own key. */
.fkp_diagnostic_alert__summary__item__body {
    display: flex;
    flex-wrap: wrap;
    column-gap: 10px;
}

/* An address list, a version or a server name has nowhere to break and would widen the row. */
.fkp_diagnostic_alert__summary__item__key {
    min-width: 0;
    overflow-wrap: anywhere;
}

.fkp_diagnostic_alert__summary__item__value {
    flex: 1 1 8rem;
    min-width: 0;
    overflow-wrap: anywhere;
}

.fkp_diagnostic_alert__summary__item--info {
    color: var(--text-color-medium, CanvasText);
}

.fkp_diagnostic_alert__summary__item--error {
    color: var(--error-color-medium, red);
}

.fkp_diagnostic_alert__summary__item--warning {
    color: var(--warn-color-medium, orange);
}

.fkp_diagnostic_alert__summary__item--success {
    color: var(--success-color-medium, green);
}

.fkp_diagnostic_alert__summary__item__icon {
    width: 16px;
    height: 16px;
}
`;
