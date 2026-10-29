import { useLayoutEffect, useState, useSyncExternalStore } from 'react';
import { gridPageCapacity, groupedPageStarts, pageForOffset } from '../lib/pagination';

const subscribeToPhoneWidth = (notify: () => void) => {
  const query = window.matchMedia('(max-width: 600px)');
  query.addEventListener('change', notify);
  return () => query.removeEventListener('change', notify);
};
export function usePageSize(desktop: number, phone: number) {
  const narrow = useSyncExternalStore(subscribeToPhoneWidth, () => window.matchMedia('(max-width: 600px)').matches, () => false);
  return narrow ? phone : desktop;
}

/** CSS owns columns; observe the actual grid, including dialogs and sidebar changes. */
export function useGridPageSize({ compact = false, rowHeight = 150 } = {}) {
  const [grid, setGrid] = useState<HTMLDivElement | null>(null);
  const [layout, setLayout] = useState({ pageSize: 12, columns: 4 });
  useLayoutEffect(() => {
    if (!grid) return;
    let timer: ReturnType<typeof setTimeout>;
    const measure = () => {
      if (!grid.clientWidth) return;
      const tracks = getComputedStyle(grid).gridTemplateColumns;
      const columns = tracks === 'none' ? 1 : Math.max(1, tracks.trim().split(/\s+/).length);
      const next = gridPageCapacity(columns, grid.clientWidth, compact ? window.innerHeight : undefined, rowHeight);
      setLayout(previous => previous.pageSize === next && previous.columns === columns ? previous : { pageSize: next, columns });
    };
    // Height changes (loading, short final pages, card contents) cannot alter capacity.
    let lastWidth = 0;
    const observer = new ResizeObserver(entries => {
      const width = entries[0].contentRect.width;
      if (width === lastWidth) return;
      lastWidth = width;
      schedule();
    });
    const schedule = () => { clearTimeout(timer); timer = setTimeout(measure, 120); };
    measure();
    observer.observe(grid);
    if (compact) window.addEventListener('resize', schedule);
    return () => { observer.disconnect(); clearTimeout(timer); window.removeEventListener('resize', schedule); };
  }, [grid, compact, rowHeight]);
  return { grid: setGrid, ...layout };
}

function useRecordPosition(resetKey: string, total?: number) {
  const [position, setPosition] = useState({ offset: 0, key: resetKey });
  const offset = position.key !== resetKey ? 0 : total === undefined ? position.offset : Math.min(position.offset, Math.max(0, total - 1));
  // Normalize scope/count changes so returning to an earlier filter or growing a
  // previously shortened editor cannot resurrect an obsolete navigation offset.
  if (position.key !== resetKey || position.offset !== offset) setPosition({ offset, key: resetKey });
  const setOffset = (next: number) => setPosition({ offset: Math.max(0, next), key: resetKey });
  return { offset, setOffset };
}

/** A filter change resets the anchor; width/height changes only reframe its page. */
export function usePagePosition(pageSize: number, resetKey = '', total?: number) {
  const { offset, setOffset } = useRecordPosition(resetKey, total);
  const page = pageForOffset(offset, pageSize, total);
  const setPage = (next: number) => setOffset(Math.max(0, next) * pageSize);
  return { page, setPage };
}

/** Account for row space reserved by brands without skipping records or changing selection. */
export function useGroupedListPage<T extends { brand_id: string }>(items: readonly T[], columns: number, pageSize: number, resetKey = '') {
  const { offset, setOffset } = useRecordPosition(resetKey, items.length);
  const starts = groupedPageStarts(items, columns, pageSize);
  const page = starts.findLastIndex(start => start <= offset);
  const rangeStart = starts[page];
  const rangeEnd = starts[page + 1] ?? items.length;
  const setPage = (next: number) => setOffset(starts[Math.max(0, Math.min(next, starts.length - 1))]);
  return { page, setPage, entries: items.slice(rangeStart, rangeEnd), pageSize, total: items.length, pageCount: starts.length, rangeStart, rangeEnd };
}

/** Selection, totals and filters always refer to the full collection, not this slice. */
export function useListPage<T>(items: readonly T[], pageSize = 12, resetKey = '') {
  const { page, setPage } = usePagePosition(pageSize, resetKey, items.length);
  return { page, setPage, entries: items.slice(page * pageSize, (page + 1) * pageSize), pageSize, total: items.length };
}

