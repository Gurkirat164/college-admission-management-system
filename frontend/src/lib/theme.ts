/** What the viewer picked. "system" follows the operating system's light or dark setting. */
export type ThemePreference = 'system' | 'light' | 'dark';

const KEY = 'admission-theme';

export function storedPreference(): ThemePreference {
  try {
    const value = localStorage.getItem(KEY);
    return value === 'light' || value === 'dark' ? value : 'system';
  } catch {
    return 'system';
  }
}

function apply(preference: ThemePreference) {
  if (preference === 'system') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = preference;
}

/** Applies a saved choice before first paint. With no saved choice the CSS follows the system. */
export function applyStoredTheme() {
  apply(storedPreference());
}

export function setPreference(preference: ThemePreference) {
  apply(preference);
  try {
    if (preference === 'system') localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, preference);
  } catch {
    // Private windows can refuse storage; the choice still applies for this visit.
  }
}
