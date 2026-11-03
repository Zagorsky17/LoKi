// The shipped LuCI bundle, evaluated outside a browser with just enough stubs to finish loading:
//
//     import { loadBundle } from '../lib/bundle.js';
//     const main = loadBundle({ uci: myUciModel });
import { webcrypto } from 'crypto';
import { createLoader } from './luciModule.js';
import { VIEW_DIR } from './paths.js';

function fakeNode() {
  const noop = () => {};
  return {
    appendChild: noop,
    removeChild: noop,
    setAttribute: noop,
    addEventListener: noop,
    removeEventListener: noop,
    replaceChildren: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    style: { setProperty: noop },
    dataset: {},
  };
}

function extendableClass(name) {
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

const classesNamed = (names) =>
  Object.fromEntries(names.map((name) => [name, extendableClass(name)]));

function defaultGlobals() {
  const noop = () => {};
  return {
    form: classesNamed([
      'Button',
      'DummyValue',
      'DynamicList',
      'Flag',
      'GridSection',
      'JSONMap',
      'ListValue',
      'Map',
      'MultiValue',
      'NamedSection',
      'TableSection',
      'TextValue',
      'TypedSection',
      'Value',
    ]),
    fs: {
      read: () => Promise.resolve(''),
      exec: () => Promise.resolve({ code: 0, stdout: '' }),
    },
    rpc: { declare: () => () => Promise.resolve({}) },
    uci: {
      load: () => Promise.resolve([]),
      get: () => null,
      get_all: () => null,
      sections: () => [],
      set: noop,
      unset: noop,
    },
    ui: {
      ...classesNamed([
        'Dropdown',
        'DynamicList',
        'Select',
        'Textarea',
        'Textfield',
      ]),
      showModal: noop,
      hideModal: noop,
      addNotification: noop,
    },
    dom: { append: noop, content: noop, findClassInstance: () => null },
    network: { getDevices: () => Promise.resolve([]) },
    widgets: classesNamed(['DeviceSelect', 'NetworkSelect']),
    E: () => fakeNode(),
    L: {
      toArray: (value) =>
        value == null ? [] : Array.isArray(value) ? value : [value],
      bind: (fn, self, ...bound) => fn.bind(self, ...bound),
      resource: (...parts) => parts.join('/'),
      error: (kind, message) => {
        throw new Error(`${kind}: ${message}`);
      },
    },
    document: Object.assign(fakeNode(), {
      getElementById: () => null,
      createElement: () => fakeNode(),
      createElementNS: () => fakeNode(),
      head: fakeNode(),
      body: fakeNode(),
      documentElement: fakeNode(),
    }),
    window: {
      crypto: webcrypto,
      location: {
        hostname: 'router.lan',
        href: 'http://router.lan/',
        protocol: 'http:',
      },
      addEventListener: noop,
      removeEventListener: noop,
      dispatchEvent: noop,
      setTimeout,
      clearTimeout,
    },
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
  };
}

export function loadBundle(globals = {}) {
  return createLoader(
    VIEW_DIR,
    Object.assign(defaultGlobals(), globals),
  )('main');
}
