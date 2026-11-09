// Loaded before every other module: services created at module scope clone
// their initial state with structuredClone, so browsers and WebViews without
// the native function must receive the fallback before that happens.
if (typeof structuredClone !== 'function') {
  globalThis.structuredClone = <T>(value: T): T =>
    JSON.parse(JSON.stringify(value)) as T;
}
