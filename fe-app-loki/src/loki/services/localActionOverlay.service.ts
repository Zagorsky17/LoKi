import type { StoreType } from './store.service';

type ServiceActionKey = 'restart' | 'start' | 'stop';

const serviceActions = new Set<ServiceActionKey>();

function setMembership<T>(set: Set<T>, value: T, active: boolean) {
  if (active) {
    set.add(value);
  } else {
    set.delete(value);
  }
}

export function setLocalServiceAction(
  action: keyof StoreType['diagnosticsActions'],
  active: boolean,
) {
  if (action === 'restart' || action === 'start' || action === 'stop') {
    setMembership(serviceActions, action, active);
  }
}

export function getLocalActionOverlay() {
  return {
    serviceActions: new Set(serviceActions),
  };
}

export function clearLocalActionOverlay() {
  serviceActions.clear();
}
