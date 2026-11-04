// language=CSS
import {
  LOKI_UCI_PACKAGE as LOKI_CBI_PREFIX,
  MONOSPACE_FONT,
} from '../../../constants';

// The terminal's screen is dark in every theme, so its colours are its own, not the theme's.
const SCREEN_TEXT = '#d4d4d4';
const ANSI_COLORS = [
  '#4a4a4a',
  '#e5675f',
  '#2fbf71',
  '#e5c07b',
  '#61afef',
  '#c678dd',
  '#4fb3d9',
  '#d4d4d4',
  '#7a7a7a',
  '#ff7b72',
  '#56d68f',
  '#f0d58c',
  '#84c1f5',
  '#d79ae8',
  '#76c8e6',
  '#ffffff',
];

const ansiStyles = ANSI_COLORS.map(
  (color, index) =>
    `.fkp_terminal__fg-${index} { color: ${color}; }\n.fkp_terminal__bg-${index} { background: ${color}; }`,
).join('\n');

export const styles = `
#cbi-${LOKI_CBI_PREFIX}-components > h3 {
    display: none;
}

/* A DummyValue's value sits in an <output> inside the theme's flex row; this makes the page
fill the column. */
#cbi-${LOKI_CBI_PREFIX}-components-_mount_node {
    display: block !important;
    container-type: inline-size;
    margin: 16px 0 22px;
    padding: 0;
}

/* The controls take what their buttons need, the terminal the rest of the row: as tall as the
controls at least, growing with its output up to its limit. */
.fkp_components-page {
    box-sizing: border-box;
    width: 100%;
    display: grid;
    grid-template-columns: minmax(17rem, max-content) minmax(0, 1fr);
    grid-gap: 10px;
}

.fkp_components-page__controls {
    align-self: start;
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    grid-row-gap: 10px;
}

.fkp_components-page__block {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    grid-row-gap: 10px;
    padding: 10px;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
}

/* A definite zero width keeps a long version string from widening the column. */
.fkp_components-page__block--versions {
    width: 0;
    min-width: 100%;
    box-sizing: border-box;
}

.fkp_components-page__block > .fkp-partial-button,
.fkp_components-page__config-buttons > .fkp-partial-button {
    width: 100%;
    min-width: 0;
    margin: 0;
}

.fkp_components-page__config-buttons {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    grid-gap: 10px;
}

.fkp_components-page__version {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    grid-column-gap: 5px;
}

.fkp_components-page__version > div {
    min-width: 0;
    overflow-wrap: anywhere;
}

.fkp_components-page__badge {
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

.fkp_components-page__run {
    display: flex;
    flex-direction: column;
    min-width: 0;
    overflow: hidden;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
}

/* The header band in the outline's colour, as a dashboard section starts. */
.fkp_components-page__run-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px 10px;
    min-height: 26px;
    padding: 4px 6px 4px 10px;
    background: var(--background-color-low, lightgray);
}

.fkp_components-page__run-title {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    color: var(--text-color-highest, inherit);
    font-weight: 700;
}

.fkp_components-page__run-title svg,
.fkp_components-page__run-status svg {
    display: block;
    flex: 0 0 auto;
    width: 16px;
    height: 16px;
}

.fkp_components-page__run-side {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
}

.fkp_components-page__run-side[hidden] {
    display: none;
}

.fkp_components-page__run-status {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    color: var(--text-color-medium, inherit);
}

.fkp_components-page__run-status .fkp_components-page__run-time {
    color: var(--text-color-medium, inherit);
    font-variant-numeric: tabular-nums;
}

.fkp_components-page__run-status--success {
    color: var(--success-color-high, green);
}

.fkp_components-page__run-status--error {
    color: var(--error-color-high, red);
}

.fkp_components-page .btn.fkp_components-page__icon-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    min-width: 26px;
    margin: 0;
    padding: 0;
}

.fkp_components-page .btn.fkp_components-page__icon-button[hidden] {
    display: none;
}

.fkp_components-page__icon-button svg {
    display: block;
    width: 15px;
    height: 15px;
}

.fkp_components-page__remove-buttons {
    display: flex;
    gap: 10px;
    margin-left: auto;
}

.fkp_terminal {
    position: relative;
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    min-height: 0;
}

/* A console's dark screen, a shade of the theme's own background. */
.fkp_components-page .fkp_terminal__output {
    box-sizing: border-box;
    flex: 1 1 auto;
    min-height: 12rem;
    max-height: max(18rem, 62vh);
    margin: 0;
    padding: 8px 10px;
    overflow-x: hidden;
    overflow-y: auto;
    overscroll-behavior: contain;
    border: 0;
    border-radius: 0;
    color-scheme: dark;
    background: #191919;
    background: color-mix(in srgb, var(--background-color-high, #fff) 6%, #101010);
    color: ${SCREEN_TEXT};
    font-family: ${MONOSPACE_FONT};
    font-size: 13px;
    line-height: 1.45;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    word-break: normal;
    cursor: text;
    user-select: text;
}

.fkp_terminal--focused .fkp_terminal__output {
    box-shadow: inset 0 0 0 1px var(--primary-color-medium, dodgerblue);
}

.fkp_terminal__input {
    position: absolute;
    top: 0;
    left: 0;
    width: 1px;
    height: 1px;
    margin: 0;
    padding: 0;
    border: 0;
    opacity: 0;
    resize: none;
    overflow: hidden;
    pointer-events: none;
}

${ansiStyles}

.fkp_terminal__inverse:not([class*="fkp_terminal__bg-"]) {
    background: ${SCREEN_TEXT};
}

.fkp_terminal__inverse:not([class*="fkp_terminal__fg-"]) {
    color: #101010;
}

.fkp_terminal__bold { font-weight: 700; }
.fkp_terminal__dim { opacity: 0.7; }
.fkp_terminal__italic { font-style: italic; }
.fkp_terminal__underline { text-decoration: underline; }

/* A hollow block while the terminal is not typed into, a blinking one while it is. */
.fkp_terminal__cursor {
    box-shadow: inset 0 0 0 1px #8a8a8a;
}

.fkp_terminal--focused .fkp_terminal__cursor {
    color: #101010;
    background: ${SCREEN_TEXT};
    box-shadow: none;
    animation: fkp_terminal-blink 1.1s steps(1) infinite;
}

@keyframes fkp_terminal-blink {
    50% {
        color: inherit;
        background: transparent;
    }
}

/* Below about 20rem of terminal beside the controls, the two stack. */
@container (max-width: 599px) {
    .fkp_components-page {
        grid-template-columns: minmax(0, 1fr);
    }

    .fkp_components-page .fkp_terminal__output {
        max-height: max(16rem, 55vh);
    }
}
`;
