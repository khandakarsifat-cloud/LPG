import { useDeferredValue, useState } from 'react';
import { useFinancialEntries, type FinancialEntryFilters } from '../../hooks/useFinancialTypes';
import { allocationText, customCategoryOptions, financialCategoryLabel } from '../../lib/financial';
import { businessLines, businessNames } from '../../types/financial';
import { formatBDT } from '../../lib/formatBDT';
import { DatePicker } from '../ui/DatePicker';
import { Pagination } from '../ui/Pagination';
import { FinancialEntryDetails } from './FinancialEntryDetails';

const empty: FinancialEntryFilters = { search: '', category: '', business: '', from: '', to: '' };
export function FinancialEntries() {
 const [filters, setFilters] = useState(empty); const [page, setPage] = useState(0); const [selected, setSelected] = useState<string | null>(null);
 const deferred = useDeferredValue(filters); const q = useFinancialEntries(deferred, page);
 const set = (key: keyof FinancialEntryFilters, value: string) => { setFilters(p => ({ ...p, [key]: value })); setPage(0); };
 return <section className="accounting-card financial-entries"><header><div><h2>Financial entries</h2><p className="finance-note">Recorded entries and returned funds.</p></div><span className="finance-note">{q.data?.total ?? 0} entries</span></header>
  <div className="financial-entry-filters"><label className="input-group"><span className="input-label">Search</span><input className="input-field" aria-label="Search financial entries" value={filters.search} placeholder="Type or description" onChange={e => set('search', e.target.value)} /></label>
   <label className="input-group"><span className="input-label">Category</span><select className="input-field" aria-label="Entry category" value={filters.category} onChange={e => set('category', e.target.value)}><option value="">All categories</option>{customCategoryOptions.map(c => <option value={c.label.toLowerCase()} key={c.value}>{c.label}</option>)}</select></label>
   <label className="input-group"><span className="input-label">Business</span><select className="input-field" aria-label="Entry business" value={filters.business} onChange={e => set('business', e.target.value)}><option value="">All businesses</option>{businessLines.map(b => <option value={b} key={b}>{businessNames[b]}</option>)}</select></label>
   <div className="input-group"><span className="input-label">From</span><DatePicker label="Entries from" value={filters.from} max={filters.to || undefined} onChange={v => set('from', v)} /></div><div className="input-group"><span className="input-label">To</span><DatePicker label="Entries to" value={filters.to} min={filters.from || undefined} onChange={v => set('to', v)} /></div>
  </div>
  {q.isPending && <p role="status">Loading financial entries…</p>}{q.error && <p role="alert" className="payment-error">{q.error.message}<button className="btn btn-secondary" onClick={() => void q.refetch()}>Retry</button></p>}
  {q.data && <><div className="finance-table-scroll"><table className="finance-table"><thead><tr><th>Entry</th><th>Category</th><th>Business</th><th>Wallet</th><th>Entry amount</th></tr></thead><tbody>{q.data.entries.map(e => <tr key={e.entry_id}>
   <td><button className="finance-entry-link" onClick={() => setSelected(e.entry_id)}><strong>{e.type_name}</strong><small>{e.occurred_on}{e.reversal_of ? ' · Returned funds' : ''}</small><span>{e.description}</span></button></td>
   <td data-label="Category">{financialCategoryLabel(e.account)}</td><td data-label="Business">{allocationText(e.allocations)}</td><td data-label="Wallet">{e.wallet_name}</td><td data-label="Amount" className="finance-money"><strong>{formatBDT(e.amount)}</strong>{e.returned > 0 && <small>Returned {formatBDT(e.returned)}</small>}</td>
  </tr>)}</tbody></table></div>{q.data.total === 0 && <p className="finance-empty">No financial entries match these filters.</p>}<Pagination page={page} pageSize={25} total={q.data.total} onChange={setPage} busy={q.isFetching} label="financial entries" alwaysVisible /></>}
  {selected && <FinancialEntryDetails id={selected} onClose={() => setSelected(null)} />}
 </section>;
}
