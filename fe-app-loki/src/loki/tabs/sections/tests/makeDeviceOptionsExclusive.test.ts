import { describe, expect, it } from 'vitest';

import { makeDeviceOptionsExclusive } from '../conditions';

function deviceOption(values: string[]) {
  const widget = {
    values,
    getValue() {
      return this.values;
    },
    setValue(next: string[]) {
      this.values = next;
    },
  };
  return { widget } as unknown as CBIOption & {
    widget: typeof widget;
    onDeviceWidgetReady: (sectionId: string, widget: unknown) => void;
    onDeviceListChange: (sectionId: string, values: string[]) => void;
  };
}

function pair(filteredValues: string[], forcedValues: string[]) {
  const filtered = deviceOption(filteredValues);
  const forced = deviceOption(forcedValues);
  makeDeviceOptionsExclusive(filtered, forced);
  filtered.onDeviceWidgetReady('section', filtered.widget);
  forced.onDeviceWidgetReady('section', forced.widget);
  return { filtered, forced };
}

describe('two device lists that exclude each other', () => {
  it('drops a newly filtered device from forced routing', () => {
    const { filtered, forced } = pair(
      ['192.0.2.1/32'],
      ['192.0.2.1/32', '192.0.2.2/32'],
    );

    filtered.onDeviceListChange('section', filtered.widget.values);

    expect(forced.widget.values).toEqual(['192.0.2.2/32']);
  });

  it('drops a newly forced device from the device filter', () => {
    const { filtered, forced } = pair(
      ['192.0.2.1/32'],
      ['192.0.2.1/32', '192.0.2.2/32'],
    );

    forced.onDeviceListChange('section', forced.widget.values);

    expect(filtered.widget.values).toEqual([]);
  });

  it('does not bounce the change back', () => {
    const { filtered, forced } = pair(['192.0.2.1/32'], ['192.0.2.1/32']);

    filtered.onDeviceListChange('section', filtered.widget.values);

    expect(filtered.widget.values).toEqual(['192.0.2.1/32']);
    expect(forced.widget.values).toEqual([]);
  });
});
