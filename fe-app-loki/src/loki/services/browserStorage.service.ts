// A browser blocking site data throws on the property, and a thumbnail render has no window.
function getStorage(name: 'sessionStorage' | 'localStorage'): Storage | null {
  if (typeof window === 'undefined') {
    return null;
  }

  try {
    return window[name];
  } catch {
    return null;
  }
}

export function getSessionStorage() {
  return getStorage('sessionStorage');
}

export function getLocalStorage() {
  return getStorage('localStorage');
}
