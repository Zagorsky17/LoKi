import cx from 'clsx';
import { useAtomValue } from 'jotai';
import { createPortal } from 'react-dom';

import { AlertCircle, CheckCircle, Info, X } from '~/components/shared/FeatherIcons';
import { dismissToast, toastsAtom, type ToastKind } from '~/store/toast';

import s from './Toast.module.scss';

const ICONS: Record<ToastKind, typeof Info> = {
  success: CheckCircle,
  error: AlertCircle,
  info: Info,
};

export function Toaster() {
  const toasts = useAtomValue(toastsAtom);

  if (toasts.length === 0) return null;

  return createPortal(
    <div className={s.container} role="region" aria-live="polite">
      {toasts.map(({ id, kind, message }) => {
        const Icon = ICONS[kind];
        return (
          <div key={id} className={cx(s.toast, s[kind])}>
            <span className={s.icon}>
              <Icon size={18} />
            </span>
            <span className={s.message}>{message}</span>
            <button className={s.close} onClick={() => dismissToast(id)} aria-label="Close">
              <X size={16} />
            </button>
          </div>
        );
      })}
    </div>,
    document.body,
  );
}
