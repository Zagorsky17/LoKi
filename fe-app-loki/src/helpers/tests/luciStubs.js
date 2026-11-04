import { webcrypto } from 'node:crypto';

export function installUciStub(sections = {}) {
  const stub = createUciStub(sections);
  globalThis.uci = stub;
  return stub;
}

export function installLuciStubs(sections = {}, widgets = {}) {
  const uci = createUciStub(sections);

  for (const [name, value] of Object.entries(defaultStubs(uci, widgets))) {
    globalThis[name] = value;
  }

  return uci;
}

function createUciStub(sections = {}) {
  const values = {};

  const ensure = (name, type) => {
    values[name] ??= { '.name': name, '.type': type || 'server' };
    return values[name];
  };

  for (const [name, section] of Object.entries(sections)) {
    const target = ensure(name, section['.type']);
    Object.assign(target, section, { '.name': name });
  }

  let anonymous = 0;

  return {
    values,
    state: {
      values: { loki: values },
      changes: {},
      deletes: {},
      creates: {},
    },
    get(_package, sectionId, option) {
      const section = values[sectionId];
      if (!section) return null;
      if (option === undefined) return section;
      return section[option] === undefined ? null : section[option];
    },
    get_all(_package, sectionId) {
      return values[sectionId] || null;
    },
    set(_package, sectionId, option, value) {
      ensure(sectionId)[option] = value;
    },
    unset(_package, sectionId, option) {
      delete values[sectionId]?.[option];
    },
    add(_package, type) {
      anonymous += 1;
      const name = `cfg${String(anonymous).padStart(6, '0')}`;
      ensure(name, type);
      return name;
    },
    remove(_package, sectionId) {
      delete values[sectionId];
    },
    sections(_package, type) {
      return Object.values(values).filter(
        (section) => !type || section['.type'] === type,
      );
    },
    load() {
      return Promise.resolve();
    },
  };
}

function defaultStubs(uci, widgets) {
  const noop = () => {};
  const element = () => ({
    setAttribute: noop,
    appendChild: noop,
    addEventListener: noop,
    replaceChildren: noop,
    querySelector: () => null,
    style: { setProperty: noop },
    classList: { add: noop, remove: noop, toggle: noop },
  });

  return {
    uci,
    fs: { exec: () => Promise.resolve({ code: 0, stdout: '{}' }) },
    ui: {
      showModal(_title, _children, ...classes) {
        classes.forEach((name) => {
          if (/\s/u.test(`${name}`)) {
            throw new Error(`invalid modal class token: ${name}`);
          }
        });
      },
      hideModal: noop,
      ...UI_CLASSES,
    },
    dom: {
      append: noop,
      content: noop,
      findClassInstance: (node) => node?.instance || null,
    },
    form: FORM_CLASSES,
    rpc: { declare: () => () => Promise.resolve([]) },
    window: {
      crypto: webcrypto,
      location: { hostname: 'router.lan' },
      setTimeout: noop,
      addEventListener: noop,
      removeEventListener: noop,
      dispatchEvent: noop,
    },
    document: {
      getElementById: (id) => widgets[id] || null,
      querySelector: () => null,
      head: { appendChild: noop },
      body: { appendChild: noop, removeChild: noop },
      createElement: element,
      createElementNS: element,
    },
    E: () => element(),
    network: { getDevices: () => Promise.resolve([]) },
  };
}

function extendableWidget(name) {
  function Widget() {}
  Widget.widget = name;
  Widget.prototype = {};
  Widget.extend = function extend(members) {
    function Subclass() {}
    Subclass.widget = name;
    Subclass.prototype = Object.assign(Object.create(this.prototype), members);
    Subclass.extend = extend;
    return Subclass;
  };
  return Widget;
}

const FORM_CLASSES = Object.fromEntries(
  [
    'DummyValue',
    'DynamicList',
    'Flag',
    'GridSection',
    'ListValue',
    'MultiValue',
    'NamedSection',
    'TableSection',
    'TextValue',
    'TypedSection',
    'Value',
  ].map((name) => [name, extendableWidget(name)]),
);

const UI_CLASSES = Object.fromEntries(
  ['Dropdown', 'DynamicList', 'Textarea', 'Textfield'].map((name) => [
    name,
    extendableWidget(name),
  ]),
);

export function createFormSectionStub() {
  const noop = () => {};
  const options = [];

  const section = {
    options,
    option(widget, name, title, description) {
      const option = Object.assign(Object.create(widget?.prototype ?? null), {
        widget: widget && widget.widget ? widget.widget : 'unknown',
        name,
        title,
        description,
        choices: [],
        dependencies: [],
        value(key, label) {
          this.choices.push([key, label]);
          return this;
        },
        depends(first, second) {
          this.dependencies.push(
            typeof first === 'object' && first !== null
              ? first
              : { [first]: second },
          );
          return this;
        },
      });
      options.push(option);
      return option;
    },
    tab: noop,
    taboption(_tab, ...args) {
      return section.option(...args);
    },
  };

  return section;
}
