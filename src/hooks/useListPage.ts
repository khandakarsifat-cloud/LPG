import { useState, useSyncExternalStore } from 'react';

const subscribeToPhoneWidth = (notify: () => void) => {
  const query = window.matchMedia('(max-width: 600px)');
  query.addEventListener('change', notify);
  return () => query.removeEventListener('change', notify);
};
export function usePageSize(desktop: number, phone: number) {
  const narrow = useSyncExternalStore(subscribeToPhoneWidth, () => window.matchMedia('(max-width: 600px)').matches, () => false);
  return narrow ? phone : desktop;
}

/** Selection, totals and filters always refer to the full collection, not this slice. */
export function useListPage<T>(items: readonly T[], pageSize = 12, resetKey = '') {
  const key = JSON.stringify([resetKey, pageSize]);
  const [position, setPosition] = useState({ page: 0, key });
  const page = Math.min(position.key === key ? position.page : 0, Math.max(0, Math.ceil(items.length / pageSize) - 1));
  const setPage = (next: number) => setPosition({ page: Math.max(0, next), key });
  return { page, setPage, entries: items.slice(page * pageSize, (page + 1) * pageSize), pageSize, total: items.length };
}

