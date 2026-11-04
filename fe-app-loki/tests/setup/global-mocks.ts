// What LuCI hands the bundle, for a test importing a module directly: only what a module needs
// while it is evaluated, such as rpc.declare() at module scope. They are `const` in src/luci.d.ts,
// so they are installed through the object.
const globals = globalThis as unknown as Record<string, unknown>;

globals._ = (key: string) => key;

globals.rpc = {
  declare: () => () => Promise.resolve([]),
};

function extendableClass(name: string) {
  function Widget() {}
  (Widget as unknown as { widget: string }).widget = name;
  Widget.prototype = {};
  (Widget as unknown as { extend: unknown }).extend = function extend(
    this: { prototype: object },
    members: object,
  ) {
    function Subclass() {}
    (Subclass as unknown as { widget: string }).widget = name;
    Subclass.prototype = Object.assign(Object.create(this.prototype), members);
    (Subclass as unknown as { extend: unknown }).extend = extend;
    return Subclass;
  };
  return Widget;
}

const classesNamed = (names: string[]) =>
  Object.fromEntries(names.map((name) => [name, extendableClass(name)]));

globals.ui = {
  ...classesNamed(['DynamicList']),
  showModal: () => undefined,
  hideModal: () => undefined,
};

globals.form = classesNamed([
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
]);

// luci.js installs String.prototype.format, which view modules use.
if (typeof (String.prototype as { format?: unknown }).format !== 'function') {
  Object.defineProperty(String.prototype, 'format', {
    value: function format(this: string, ...args: unknown[]): string {
      let index = 0;
      return this.replace(/%[sdq]/g, (match) => {
        const value = args[index];
        index += 1;
        if (match === '%d') {
          return `${Number(value)}`;
        }
        return `${value}`;
      });
    },
    writable: true,
    configurable: true,
  });
}
