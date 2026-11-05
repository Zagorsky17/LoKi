import * as Dialog from '@radix-ui/react-dialog';
import cx from 'clsx';
import * as React from 'react';

import s0 from './Modal.module.scss';

// react-modal 的 className 支持对象形式；迁移到 Radix 后过渡由 [data-state] 驱动，
// 这里只取 base，afterOpen/beforeClose 已无意义但保留类型以兼容调用方。
type ClassNameObj = { base?: string; afterOpen?: string; beforeClose?: string };

type Props = {
  isOpen: boolean;
  onRequestClose?: (...args: any[]) => any;
  onAfterOpen?: () => void;
  className?: string | ClassNameObj;
  overlayClassName?: string;
  shouldCloseOnOverlayClick?: boolean;
  shouldCloseOnEsc?: boolean;
  /** 无障碍标题。不传时用视觉隐藏的默认值，避免 Radix 缺少 Title 的告警。 */
  title?: string;
  children: React.ReactNode;
};

function resolveClassName(className: Props['className']): string | undefined {
  if (!className) return undefined;
  return typeof className === 'string' ? className : className.base;
}

function ModalBase({
  isOpen,
  onRequestClose,
  onAfterOpen,
  className,
  overlayClassName,
  shouldCloseOnOverlayClick = true,
  shouldCloseOnEsc = true,
  title = 'Dialog',
  children,
}: Props) {
  const onOpenChange = React.useCallback(
    (open: boolean) => {
      if (!open) onRequestClose && onRequestClose();
    },
    [onRequestClose],
  );

  // react-modal 的 onAfterOpen 对应 Radix 打开后的自动聚焦时机
  const onOpenAutoFocus = React.useCallback(
    (e: Event) => {
      if (onAfterOpen) {
        e.preventDefault();
        onAfterOpen();
      }
    },
    [onAfterOpen],
  );

  return (
    <Dialog.Root open={isOpen} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className={cx(s0.overlay, overlayClassName)} />
        <Dialog.Content
          className={cx(s0.content, resolveClassName(className))}
          onOpenAutoFocus={onOpenAutoFocus}
          onInteractOutside={(e) => {
            if (!shouldCloseOnOverlayClick) e.preventDefault();
          }}
          onEscapeKeyDown={(e) => {
            if (!shouldCloseOnEsc) e.preventDefault();
          }}
          aria-describedby={undefined}
        >
          <Dialog.Title className="visually-hidden">{title}</Dialog.Title>
          {children}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export default React.memo(ModalBase);
