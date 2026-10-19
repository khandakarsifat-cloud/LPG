import { ChevronLeft, ChevronRight } from 'lucide-react';
import './pagination.css';

export function Pagination({ page, pageSize, total, onChange, label = 'results', busy = false, alwaysVisible = false }: {
  page: number; pageSize: number; total: number; onChange: (page: number) => void; label?: string; busy?: boolean; alwaysVisible?: boolean;
}) {
  if (!alwaysVisible && total <= pageSize && page === 0) return null;
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const current = Math.min(page, pages - 1);
  const numbers = [...new Set([0, current - 1, current, current + 1, pages - 1])].filter(n => n >= 0 && n < pages).sort((a, b) => a - b);
  return <nav className="list-pagination" aria-label={`${label} pages`}>
    <span>{total ? `${current * pageSize + 1}–${Math.min((current + 1) * pageSize, total)} of ${total.toLocaleString('en-BD')}` : '0'} {label}</span>
    <div className="list-page-buttons">
      <button type="button" aria-label="Previous page" disabled={busy || current === 0} onClick={() => onChange(current - 1)}><ChevronLeft size={15} /></button>
      {numbers.map((n, index) => <span key={n} className="list-page-number">{index > 0 && n > numbers[index - 1] + 1 && <span className="list-page-gap">…</span>}
        <button type="button" aria-label={`Page ${n + 1}`} aria-current={n === current ? 'page' : undefined} disabled={busy} onClick={() => onChange(n)}>{n + 1}</button></span>)}
      <button type="button" aria-label="Next page" disabled={busy || current >= pages - 1} onClick={() => onChange(current + 1)}><ChevronRight size={15} /></button>
    </div>
  </nav>;
}

/** For existing APIs that return a look-ahead row rather than an exact count. */
export function PageNavigation({ page, hasMore, onChange, label, busy = false }: {
  page: number; hasMore: boolean; onChange: (page: number) => void; label: string; busy?: boolean;
}) {
  if (page === 0 && !hasMore) return null;
  return <nav className="list-pagination" aria-label={`${label} pages`}><span>Page {page + 1}</span><div className="list-page-buttons">
    <button type="button" disabled={busy || page === 0} onClick={() => onChange(page - 1)} aria-label="Previous page"><ChevronLeft size={15} /></button>
    <button type="button" disabled={busy || !hasMore} onClick={() => onChange(page + 1)} aria-label="Next page"><ChevronRight size={15} /></button>
  </div></nav>;
}
