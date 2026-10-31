import { useState } from 'react';
import { useJournalEntries, useJournalLines } from '../../hooks/useAccounting';
import type { JournalEntry, JournalFilters } from '../../types/accounting';
import { formatBDT } from '../../lib/formatBDT';
import { Pagination } from '../ui/Pagination';

export function JournalAudit({ filters, accounts }: { filters: JournalFilters; accounts: { account: string; name: string }[] }) {
  const [page, setPage] = useState(0); const [search, setSearch] = useState(''); const [source, setSource] = useState(''); const [account, setAccount] = useState('');
  const queryFilters = { ...filters, search, source, account }; const q = useJournalEntries(queryFilters, page);
  return <section className="journal-audit"><p className="finance-note">Advanced accounting evidence for reconciliation and troubleshooting. Entries balance debits and credits; amounts are not additional payments.</p>
    <div className="journal-filters"><label className="input-group"><span className="input-label">Search journal</span><input className="input-field" placeholder="Description, reference or entry number" value={search} onChange={e => { setSearch(e.target.value); setPage(0); }} /></label><label className="input-group"><span className="input-label">Source</span><select className="input-field" value={source} onChange={e => { setSource(e.target.value); setPage(0); }}><option value="">All sources</option>{q.data?.sources.map(s => <option key={s} value={s}>{s.replaceAll('_', ' ')}</option>)}</select></label><label className="input-group"><span className="input-label">Account</span><select className="input-field" value={account} onChange={e => { setAccount(e.target.value); setPage(0); }}><option value="">All accounts</option>{accounts.map(a => <option key={a.account} value={a.account}>{a.name}</option>)}</select></label></div>
    {q.isPending && <p role="status">Loading journal…</p>}{q.error && <p className="payment-error" role="alert">{q.error.message}<button className="btn btn-secondary" onClick={() => void q.refetch()}>Retry</button></p>}
    {q.data && <>{q.data.entries.map(entry => <JournalCard key={entry.journal_id} entry={entry} filters={filters} />)}{!q.data.total && <p>No matching journal entries.</p>}<Pagination page={page} pageSize={12} total={q.data.total} onChange={setPage} busy={q.isFetching} label="journal entries" alwaysVisible /></>}
  </section>;
}
function JournalCard({ entry, filters }: { entry: JournalEntry; filters: JournalFilters }) {
  const [open, setOpen] = useState(false);
  return <details className="journal-entry" onToggle={e => setOpen(e.currentTarget.open)}><summary><div><strong>{entry.description}</strong><small>{entry.occurred_on} · #{entry.entry_no} · {entry.source.replaceAll('_', ' ')}{entry.estimated ? ' · Development estimates included' : ''}</small></div><span>{entry.line_count} lines · {formatBDT(entry.total_debit)}</span></summary>
    {open && <><p className="finance-note journal-reference">Transaction: {entry.transaction_reference ?? entry.source_id} · Journal: {entry.journal_id}</p><JournalLines filters={filters} id={entry.journal_id} /></>}
  </details>;
}
function JournalLines({ filters, id }: { filters: JournalFilters; id: string }) {
  const [page, setPage] = useState(0); const q = useJournalLines(filters, id, page);
  return <>{q.isPending && <p role="status">Loading entry lines…</p>}{q.error && <p className="payment-error" role="alert">{q.error.message}</p>}{q.data && <><div className="accounting-table-wrap" aria-busy={q.isFetching}><table><thead><tr><th>Account / related record</th><th>Activity</th><th>Debit</th><th>Credit</th></tr></thead><tbody>{q.data.entries.map(l => <tr key={l.line_no}><td><strong>{l.account}</strong>{l.entity_name !== l.account && <small>{l.entity_name}</small>}</td><td>{l.business_category}</td><td>{l.amount > 0 ? formatBDT(l.amount) : '—'}</td><td>{l.amount < 0 ? formatBDT(-l.amount) : '—'}</td></tr>)}</tbody></table></div><Pagination page={page} pageSize={25} total={q.data.total} onChange={setPage} busy={q.isFetching} label="entry lines" alwaysVisible /></>}</>;
}
