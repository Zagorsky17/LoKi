import { beforeEach, describe, expect, it } from 'vitest';

import { installUciStub } from '../../../../../helpers/tests/luciStubs';
import { addSubscriptionUrlItemOptions } from '../options';
import { validateSubscriptionUrlEntry } from '../model';

beforeEach(() => {
  installUciStub({});
});

const REMOTE_ONLY = [
  'subscription_update_enabled',
  'subscription_update_interval',
  'download_via_proxy_enabled',
  'download_via_proxy_section',
  '_subscription_headers',
  'show_dashboard_metadata',
];

const ALWAYS = ['tag', 'url', 'server_filter_mode'];

function shownFor(source: string) {
  const dependencies = new Map<string, Array<Record<string, unknown>>>();
  const section = {
    map: {},
    option: (_type: unknown, name: string) => {
      dependencies.set(name, []);
      return {
        depends(key: unknown, value: unknown) {
          dependencies
            .get(name)!
            .push(
              typeof key === 'string'
                ? { [key]: value }
                : (key as Record<string, unknown>),
            );
        },
        value() {},
      };
    },
  };

  addSubscriptionUrlItemOptions(section as unknown as CBISection, {
    parentSectionId: () => 'proxy',
  });

  return [...dependencies.entries()]
    .filter(
      ([, depends]) =>
        !depends.length ||
        depends.some(
          (dependency) =>
            !(dependency.url instanceof RegExp) || dependency.url.test(source),
        ),
    )
    .map(([name]) => name);
}

describe('a remote subscription', () => {
  it.each([...REMOTE_ONLY, ...ALWAYS])('is offered %s', (name) => {
    expect(shownFor('https://example.com/sub')).toContain(name);
  });
});

describe('a local subscription', () => {
  it.each(REMOTE_ONLY)('is not offered %s', (name) => {
    expect(shownFor('/etc/loki/subscription.txt')).not.toContain(name);
  });

  it.each(ALWAYS)('is offered %s', (name) => {
    expect(shownFor('/etc/loki/subscription.txt')).toContain(name);
  });
});

describe('validateSubscriptionUrlEntry', () => {
  it('accepts a URL', () => {
    expect(
      validateSubscriptionUrlEntry('settings', 'https://example.com/sub'),
    ).toBe(true);
  });

  it('accepts an absolute local path', () => {
    expect(
      validateSubscriptionUrlEntry('settings', '/etc/loki/subscription.txt'),
    ).toBe(true);
  });

  it('refuses a relative path, saying why', () => {
    expect(
      validateSubscriptionUrlEntry('settings', 'relative/subscription.txt'),
    ).toBe('URL or absolute path only');
  });
});
