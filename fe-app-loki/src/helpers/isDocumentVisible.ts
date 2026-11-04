// Feeds stop behind a hidden tab. Without a document, as in a check loading the bundle, the answer is yes.
export function isDocumentVisible() {
  return (
    typeof document === 'undefined' ||
    !document.visibilityState ||
    document.visibilityState === 'visible'
  );
}

// Runs the callback now while the page is in view, and otherwise the moment it
// comes back: a poll due behind a hidden tab waits for someone to look at it.
export function whenDocumentVisible(callback: () => void) {
  if (isDocumentVisible()) {
    callback();
    return;
  }

  const onChange = () => {
    if (!isDocumentVisible()) {
      return;
    }
    document.removeEventListener('visibilitychange', onChange);
    callback();
  };
  document.addEventListener('visibilitychange', onChange);
}
