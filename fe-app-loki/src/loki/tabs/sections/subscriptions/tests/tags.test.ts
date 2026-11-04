import { describe, expect, it } from 'vitest';

import { installUciStub } from '../../../../../helpers/tests/luciStubs';
import { addSubscriptionUrlItemOptions } from '../options';
import { configuredSubscriptionTags, nextSubscriptionTag } from '../model';

const SECTION = 'section_probe';

function listOption(values: string[]) {
  return { formvalue: () => values } as unknown as CBIOption;
}

function storedSubscription(
  sections: Record<string, Record<string, string>>,
  itemId: string,
  tag: string,
) {
  sections[itemId] = {
    '.type': 'subscription_url',
    section: SECTION,
    url: `https://example.com/${itemId}`,
    tag,
  };
  return itemId;
}

describe('naming a subscription that is being added', () => {
  it('names the first one of a section sub1', () => {
    installUciStub({});

    expect(nextSubscriptionTag(SECTION, listOption([]))).toBe('sub1');
  });

  it('numbers it after the subscriptions the section already has', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    installUciStub(sections);

    expect(nextSubscriptionTag(SECTION, listOption(['sub_first']))).toBe(
      'sub2',
    );
  });

  it('does not fill a gap the numbering left', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub2');
    storedSubscription(sections, 'sub_second', 'sub3');
    installUciStub(sections);

    expect(
      nextSubscriptionTag(SECTION, listOption(['sub_first', 'sub_second'])),
    ).toBe('sub4');
  });

  it('numbers past the highest tag, not past the count', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    storedSubscription(sections, 'sub_second', 'sub5');
    installUciStub(sections);

    expect(
      nextSubscriptionTag(SECTION, listOption(['sub_first', 'sub_second'])),
    ).toBe('sub6');
  });

  it('does not count a subscription the user named', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'office');
    installUciStub(sections);

    expect(nextSubscriptionTag(SECTION, listOption(['sub_first']))).toBe(
      'sub1',
    );
  });

  it('takes the numbers of subscriptions removed from the list', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    storedSubscription(sections, 'sub_second', 'sub2');
    installUciStub(sections);

    expect(nextSubscriptionTag(SECTION, listOption([]))).toBe('sub1');
  });

  it('moves past a number a subscription still in the list holds', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    storedSubscription(sections, 'sub_second', 'sub2');
    storedSubscription(sections, 'sub_third', 'sub3');
    installUciStub(sections);

    expect(
      nextSubscriptionTag(SECTION, listOption(['sub_first', 'sub_third'])),
    ).toBe('sub4');
  });

  it('does not count an address still in the add field', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    installUciStub(sections);

    expect(
      nextSubscriptionTag(
        SECTION,
        listOption(['sub_first', 'https://example.com/typed']),
      ),
    ).toBe('sub2');
  });

  it('numbers past the stored subscriptions when no list is on screen', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    storedSubscription(sections, 'sub_second', 'sub2');
    installUciStub(sections);

    expect(nextSubscriptionTag(SECTION, {} as unknown as CBIOption)).toBe(
      'sub3',
    );
  });
});

describe('the tags a section counts as taken', () => {
  it('includes a stored one', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    installUciStub(sections);
    const option = listOption(['sub_first']);

    expect(configuredSubscriptionTags(SECTION, option)).toEqual(['sub1']);
  });

  it('leaves out a subscription removed from the list', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    storedSubscription(sections, 'sub_second', 'sub2');
    installUciStub(sections);
    const option = listOption(['sub_first']);

    expect(configuredSubscriptionTags(SECTION, option)).toEqual(['sub1']);
  });

  it('leaves out the entry it is asked to skip', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    storedSubscription(sections, 'sub_second', 'sub2');
    installUciStub(sections);
    const option = listOption(['sub_first', 'sub_second']);

    expect(configuredSubscriptionTags(SECTION, option, ['sub_second'])).toEqual(
      ['sub1'],
    );
  });
});

function tagValidator(option: CBIOption, ownerId: string) {
  let validate: ((itemId: string, value: unknown) => true | string) | undefined;
  const section = {
    map: {},
    option: (_type: unknown, name: string) => {
      const created = {
        depends() {},
        value() {},
        set validate(
          handler: (itemId: string, value: unknown) => true | string,
        ) {
          if (name === 'tag') validate = handler;
        },
        get validate() {
          return validate as (itemId: string, value: unknown) => true | string;
        },
      };
      return created;
    },
  };

  addSubscriptionUrlItemOptions(section as unknown as CBISection, {
    parentSectionId: () => SECTION,
    ownerId: () => ownerId,
    itemValue: () => '',
    listOption: option,
  });

  return validate!;
}

describe('typing a tag by hand', () => {
  it('is refused when a subscription in the list already holds it', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    storedSubscription(sections, 'sub_second', 'sub2');
    installUciStub(sections);
    const option = listOption(['sub_first', 'sub_second']);

    expect(tagValidator(option, 'sub_second')('settings', 'sub1')).toBe(
      'Name already taken',
    );
  });

  it('is accepted when the subscription holding it was removed from the list', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    storedSubscription(sections, 'sub_second', 'sub2');
    installUciStub(sections);
    const option = listOption(['sub_first']);

    expect(tagValidator(option, 'sub_first')('settings', 'sub2')).toBe(true);
  });

  it('is accepted when only the subscription itself holds it', () => {
    const sections: Record<string, Record<string, string>> = {};
    storedSubscription(sections, 'sub_first', 'sub1');
    installUciStub(sections);
    const option = listOption(['sub_first']);

    expect(tagValidator(option, 'sub_first')('settings', 'sub1')).toBe(true);
  });

  it('refuses a name that would split the provider tag', () => {
    installUciStub({});
    const option = listOption([]);

    expect(tagValidator(option, SECTION)('settings', 'a/b')).toBe(
      'The / character is not allowed',
    );
  });
});
