import { useState } from 'react';
import { Monitor, Moon, Sun } from 'lucide-react';
import { setPreference, storedPreference, type ThemePreference } from '../lib/theme';

const OPTIONS: { value: ThemePreference; label: string; Icon: typeof Sun }[] = [
  { value: 'light', label: 'Light theme', Icon: Sun },
  { value: 'dark', label: 'Dark theme', Icon: Moon },
  { value: 'system', label: 'Match system theme', Icon: Monitor },
];

/** Three-way switch: the highlighted icon is the theme in use, not the one a click would switch to. */
export default function ThemeSwitch() {
  const [preference, setPreferenceState] = useState<ThemePreference>(storedPreference);
  return (
    <div className="theme-switch" role="group" aria-label="Theme">
      {OPTIONS.map(({ value, label, Icon }) => (
        <button
          key={value}
          type="button"
          aria-label={label}
          title={label}
          aria-pressed={preference === value}
          onClick={() => {
            setPreference(value);
            setPreferenceState(value);
          }}
        >
          <Icon size={15} strokeWidth={1.75} aria-hidden="true" />
        </button>
      ))}
    </div>
  );
}
