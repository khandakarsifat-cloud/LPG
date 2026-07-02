export type AppTheme = 'light' | 'dark';

export const THEME_STORAGE_KEY = 'lpg-theme';

export const isAppTheme = (value: string | null): value is AppTheme =>
  value === 'light' || value === 'dark';

export const getStoredTheme = (): AppTheme | null => {
  if (typeof window === 'undefined') return null;
  const storedTheme = window.localStorage.getItem(THEME_STORAGE_KEY);
  return isAppTheme(storedTheme) ? storedTheme : null;
};

export const getPreferredTheme = (): AppTheme => {
  if (typeof window === 'undefined') return 'light';
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
};

export const applyTheme = (theme: AppTheme) => {
  if (typeof document === 'undefined') return;
  document.documentElement.dataset.theme = theme;
  document.documentElement.style.colorScheme = theme;
};

export const persistTheme = (theme: AppTheme) => {
  if (typeof window === 'undefined') return;
  window.localStorage.setItem(THEME_STORAGE_KEY, theme);
};
