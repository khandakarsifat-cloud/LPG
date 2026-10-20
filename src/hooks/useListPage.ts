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

/** Match server pages to complete card rows in the actual workspace, including a collapsed sidebar. */
export function useGridPageSize(cardHeight = 200, gap = 8) {
  const anchor = useRef<HTMLDivElement>(null);
  const [pageSize, setPageSize] = useState(6);
  useLayoutEffect(() => {
    const element = anchor.current;
    if (!element) return;
    const workspace = element.closest('.page-content');
    const measure = () => {
      const rect = element.getBoundingClientRect();
      const columns = window.matchMedia('(max-width: 600px)').matches ? 1 : Math.max(1, Math.floor((rect.width + gap) / (240 + gap)));
      const bottom = workspace?.getBoundingClientRect().bottom ?? window.innerHeight;
      const available = bottom - rect.top - (workspace?.scrollTop ?? 0) - 12;
      const rows = Math.max(2, Math.floor((available + gap) / (cardHeight + gap)));
      const next = Math.min(rows, Math.floor(100 / columns)) * columns;
      setPageSize(previous => previous === next ? previous : next);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    if (element.parentElement) observer.observe(element.parentElement);
    if (workspace) observer.observe(workspace);
    window.addEventListener('resize', measure);
    return () => { observer.disconnect(); window.removeEventListener('resize', measure); };
  }, [cardHeight, gap]);
  return { anchor, pageSize };
}

/** Selection, totals and filters always refer to the full collection, not this slice. */
export function useListPage<T>(items: readonly T[], pageSize = 12, resetKey = '') {
  const key = JSON.stringify([resetKey, pageSize]);
  const [position, setPosition] = useState({ page: 0, key });
  const page = Math.min(position.key === key ? position.page : 0, Math.max(0, Math.ceil(items.length / pageSize) - 1));
  const setPage = (next: number) => setPosition({ page: Math.max(0, next), key });
  return { page, setPage, entries: items.slice(page * pageSize, (page + 1) * pageSize), pageSize, total: items.length };
}

