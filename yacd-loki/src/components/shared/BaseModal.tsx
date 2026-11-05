import cx from 'clsx';
import * as React from 'react';

import s from './BaseModal.module.scss';
import Modal from './Modal';

type BaseModalProps = {
  isOpen: boolean;
  onRequestClose: (...args: any[]) => unknown;
  title?: string;
  children: React.ReactNode;
};

export default function BaseModal({ isOpen, onRequestClose, title, children }: BaseModalProps) {
  return (
    <Modal
      isOpen={isOpen}
      onRequestClose={onRequestClose}
      title={title}
      className={s.cnt}
      overlayClassName={cx(s.overlay)}
    >
      {children}
    </Modal>
  );
}
