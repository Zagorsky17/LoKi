// language=CSS
import {
  LOKI_UCI_PACKAGE as LOKI_CBI_PREFIX,
  MONOSPACE_FONT,
} from '../../../constants';

export const styles = `
#cbi-${LOKI_CBI_PREFIX}-logs,
#cbi-${LOKI_CBI_PREFIX}-logs > .cbi-section-node,
#cbi-${LOKI_CBI_PREFIX}-logs .cbi-value,
#cbi-${LOKI_CBI_PREFIX}-logs-_mount_node,
.fkp_logs-page {
    box-sizing: border-box;
    width: 100% !important;
    min-width: 0 !important;
    max-width: 100% !important;
}

/* A DummyValue's value sits in an <output> inside the theme's flex row; this makes the page
fill the column. */
#cbi-${LOKI_CBI_PREFIX}-logs-_mount_node {
    display: block !important;
    margin: 16px 0 22px;
    padding: 0;
}

#cbi-${LOKI_CBI_PREFIX}-logs > h3 {
    display: none;
}

/* The search field keeps the theme's height, the one its buttons have. */
.fkp_logs-page {
    container-type: inline-size;
}

.fkp_logs-page__toolbar,
.fkp_logs-page__controls,
.fkp_logs-page__actions,
.fkp_logs-page__checkbox {
    display: flex;
    align-items: center;
}

.fkp_logs-page__toolbar {
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 0.75em;
    margin-bottom: 0.75em;
}

.fkp_logs-page__controls {
    flex: 1 1 auto;
    flex-wrap: wrap;
    min-width: 0;
    gap: 0.75em;
}

.fkp_logs-page__search {
    position: relative;
    display: flex;
    align-items: center;
    width: min(320px, 100%);
    min-width: 0;
    margin: 0;
}

.fkp_logs-page__search-icon {
    position: absolute;
    left: 8px;
    width: 16px;
    height: 16px;
    color: var(--text-color-medium);
    pointer-events: none;
}

.fkp_logs-page__search-icon svg {
    display: block;
    width: 16px;
    height: 16px;
}

.fkp_logs-page .fkp_logs-page__search-input {
    box-sizing: border-box;
    width: 100%;
    margin: 0 !important;
    padding-left: 30px !important;
}

.fkp_logs-page__checkbox {
    gap: 0.4em;
    margin: 0;
    white-space: nowrap;
    cursor: pointer;
    user-select: none;
}

.fkp_logs-page__checkbox input {
    margin: 0;
}

.fkp_logs-page__actions {
    gap: 0.4em;
}

.fkp_logs-page__output {
    display: block;
    flex: 0 0 auto;
    box-sizing: border-box;
    width: 100% !important;
    min-width: 0 !important;
    max-width: 100% !important;
    inline-size: 100% !important;
    max-inline-size: 100% !important;
    height: 65vh !important;
    min-height: 24rem;
    max-height: none !important;
    margin: 0;
    overflow-x: auto !important;
    overflow-y: auto !important;
    overscroll-behavior: contain;
    contain: inline-size;
    border-radius: 4px;
    font-family: ${MONOSPACE_FONT};
    white-space: pre;
    overflow-wrap: normal;
    word-break: normal;
    user-select: text;
}

.fkp_logs-page__output--empty {
    opacity: 0.75;
}

@container (max-width: 539px) {
    .fkp_logs-page__search {
        width: 100%;
    }

    .fkp_logs-page__actions {
        width: 100%;
    }

    .fkp_logs-page__actions .btn {
        flex: 1 1 0;
    }

    .fkp_logs-page__output {
        height: 60vh !important;
        min-height: 20rem;
    }
}
`;
