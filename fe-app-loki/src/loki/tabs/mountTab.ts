const mountNodes = new Map<string, HTMLElement>();

/**
 * The node a tab's controller is bound to, kept across renders of its form: LuCI rebuilds the
 * whole form.Map after a save, and handing back the same node keeps its scroll, search and state.
 */
export function mountTab(
  key: string,
  render: () => HTMLElement,
  initController: () => unknown,
): HTMLElement {
  let node = mountNodes.get(key);

  if (!node) {
    node = render();
    mountNodes.set(key, node);
  }

  // A controller that cannot start must not take the render down; the tab keeps what it had.
  const report = (error: unknown) =>
    console.error(`[TABS] Failed to start the ${key} controller`, error);
  try {
    Promise.resolve(initController()).catch(report);
  } catch (error) {
    report(error);
  }

  return node;
}

/** Test seam: drops the remembered nodes so each case mounts its own. */
export function resetMountedTabs(): void {
  mountNodes.clear();
}

/** The DummyValue a mounted tab declares; its value is the node the controller is bound to. */
export function mountTabOption(
  section: CBISection,
  key: string,
  tab: { render: () => HTMLElement; initController: () => unknown },
): void {
  const o = section.option(form.DummyValue, '_mount_node');
  o.rawhtml = true;
  o.cfgvalue = () => mountTab(key, tab.render, tab.initController);
}
