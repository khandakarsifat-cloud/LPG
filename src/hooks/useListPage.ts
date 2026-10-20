import { useLayoutEffect, useRef, useState, useSyncExternalStore } from 'react';

const subscribeToPhoneWidth = (notify: () => void) => {
  const query = window.matchMedia('(max-width: 600px)');
  query.addEventListener('change', notify);
  return () => query.removeEventListener('change', notify);
};
export function usePageSize(desktop: number, phone: number) {
  const narrow = useSyncExternalStore(subscribeToPhoneWidth, () => window.matchMedia('(max-width: 600px)').matches, () => false);
  return narrow ? phone : desktop;
}

/** Desktop pages have three normal-width rows; phone pages show ten cards. */
export function useGridPageSize() {
  const anchor = useRef<HTMLDivElement>(null);
  const [grid, setGrid] = useState<HTMLDivElement | null>(null);
  const [columns, setColumns] = useState(4);
  const pageSize = usePageSize(columns * 3, 10);
  useLayoutEffect(() => {
    if (!grid) return;
    const measure = () => {
      const next = Math.max(1, getComputedStyle(grid).gridTemplateColumns.trim().split(/\s+/).length);
      setColumns(previous => previous === next ? previous : next);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(grid);
    return () => observer.disconnect();
  }, [grid]);
  return { anchor, grid: setGrid, pageSize };
}

/** Selection, totals and filters always refer to the full collection, not this slice. */
export function useListPage<T>(items: readonly T[], pageSize = 12, resetKey = '') {
  const key = JSON.stringify([resetKey, pageSize]);
  const [position, setPosition] = useState({ page: 0, key });
  const page = Math.min(position.key === key ? position.page : 0, Math.max(0, Math.ceil(items.length / pageSize) - 1));
  const setPage = (next: number) => setPosition({ page: Math.max(0, next), key });
  return { page, setPage, entries: items.slice(page * pageSize, (page + 1) * pageSize), pageSize, total: items.length };
}

