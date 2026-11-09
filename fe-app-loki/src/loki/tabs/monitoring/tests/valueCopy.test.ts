import { describe, expect, it } from 'vitest';

import { shouldCopyFullMonitoringValue } from '../valueCopy';

function cell(text: string, visibleShare: number) {
  return {
    scrollWidth: 1000,
    clientWidth: Math.round(1000 * visibleShare),
    children: [],
    querySelectorAll: () => [],
    getAttribute: (name: string) => (name === 'data-copy-value' ? text : null),
    textContent: text,
  } as unknown as HTMLElement;
}

const HOST = 'cdn-edge-07.eu-central.example-content-delivery.net';

describe('copying a Monitoring value', () => {
  it('copies what was selected of a value that shows in full', () => {
    expect(shouldCopyFullMonitoringValue(cell(HOST, 1), 'cdn-edge', HOST)).toBe(
      false,
    );
  });

  it('copies the whole value once all of it is selected', () => {
    expect(shouldCopyFullMonitoringValue(cell(HOST, 1), HOST, HOST)).toBe(true);
  });

  it('copies the whole value when what shows of it is selected', () => {
    const visible = HOST.slice(0, Math.floor(HOST.length / 2));

    expect(
      shouldCopyFullMonitoringValue(cell(HOST, 0.5), `${visible}\u2026`, HOST),
    ).toBe(true);
  });

  it('copies what was selected when that is less than what shows', () => {
    expect(
      shouldCopyFullMonitoringValue(cell(HOST, 0.5), 'cdn-edge', HOST),
    ).toBe(false);
  });

  it('copies what was selected when it is not the start of the value', () => {
    const middle = HOST.slice(5, 5 + Math.floor(HOST.length / 2));

    expect(shouldCopyFullMonitoringValue(cell(HOST, 0.5), middle, HOST)).toBe(
      false,
    );
  });

  it('copies nothing special for an empty selection', () => {
    expect(shouldCopyFullMonitoringValue(cell(HOST, 0.5), '  ', HOST)).toBe(
      false,
    );
  });
});
