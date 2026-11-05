import { atom, getDefaultStore } from 'jotai';

export type ToastKind = 'success' | 'error' | 'info';

export type Toast = {
  id: number;
  kind: ToastKind;
  message: string;
};

export const toastsAtom = atom<Toast[]>([]);

const DEFAULT_DURATION_MS = 6000;

// 用默认 store，这样非组件代码（store 里的 thunk）也能弹通知
const store = getDefaultStore();
let seq = 0;

export function dismissToast(id: number) {
  store.set(toastsAtom, (prev) => prev.filter((t) => t.id !== id));
}

export function toast(kind: ToastKind, message: string, duration = DEFAULT_DURATION_MS) {
  const id = ++seq;
  store.set(toastsAtom, (prev) => [...prev, { id, kind, message }]);
  setTimeout(() => dismissToast(id), duration);
  return id;
}
