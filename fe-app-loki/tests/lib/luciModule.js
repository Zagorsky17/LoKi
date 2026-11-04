// Loads a LuCI view module the way the LuCI loader does: leading "require" strings are
// directives, and the file ends in `return baseclass.extend({...})`.
import fs from 'fs';
import path from 'path';
import { parse } from '@babel/parser';

// luci.js installs String.prototype.format, which view code uses.
if (!String.prototype.format) {
  String.prototype.format = function (...args) {
    let index = 0;
    return this.replace(/%[sd]/g, () => `${args[((index += 1), index - 1)]}`);
  };
}

const REQUIRE_DIRECTIVE = /^require ([\w.]+)(?: as (\w+))?$/;

export function createLoader(viewDir, globals = {}) {
  const loaded = new Map();

  function load(name) {
    if (loaded.has(name)) return loaded.get(name);

    const source = fs.readFileSync(path.join(viewDir, `${name}.js`), 'utf8');
    const { directives } = parse(source, {
      sourceType: 'script',
      allowReturnOutsideFunction: true,
    }).program;
    const deps = [];
    for (const directive of directives) {
      const matched = REQUIRE_DIRECTIVE.exec(directive.value.value);
      if (matched) {
        deps.push([matched[1], matched[2]]);
      }
    }

    const names = ['_', 'baseclass'];
    const values = [
      globals._ || ((text) => text),
      { extend: (value) => value },
    ];
    for (const [dep, alias] of deps) {
      if (dep === 'baseclass') continue;
      const local = alias || dep.split('.').pop();
      names.push(local);
      values.push(
        Object.prototype.hasOwnProperty.call(globals, local)
          ? globals[local]
          : load(dep.replace(/^view\.loki\./, '')),
      );
    }
    for (const [key, value] of Object.entries(globals)) {
      if (names.includes(key)) continue;
      names.push(key);
      values.push(value);
    }

    const module = new Function(...names, source)(...values);
    loaded.set(name, module);
    return module;
  }

  return load;
}
