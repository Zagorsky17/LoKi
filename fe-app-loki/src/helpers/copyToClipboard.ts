import { showToast } from './showToast';

export function copyToClipboard(text: string) {
  const textarea = document.createElement('textarea');
  textarea.value = text;
  document.body.appendChild(textarea);
  textarea.select();
  let copied = false;
  try {
    copied = document.execCommand('copy');
  } catch (error) {
    console.error('copyToClipboard', error);
  }
  showToast(
    copied ? _('Copied') : _('Failed to copy!'),
    copied ? 'success' : 'error',
  );
  document.body.removeChild(textarea);
}
