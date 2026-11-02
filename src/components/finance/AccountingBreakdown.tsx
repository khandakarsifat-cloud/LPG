import { businessLines, businessNames } from '../../types/financial';
import './finance-modals.css';
import { lazy, Suspense, useDeferredValue, useState } from 'react';
import { useTransit } from '../../hooks/useLogistics';
import { FinancialEntryDetails } from './FinancialEntryDetails';
import { useAuth } from '../../contexts/AuthContext';
import { useAccountingBreakdown, useAccountingHealth, useAccountingProduct } from '../../hooks/useAccounting';
import { usePurchaseDetails } from '../../hooks/usePurchases';
import { useEmployeeOperation, useEmployeeOverview } from '../../hooks/useEmployees';
import type { AccountingBreakdownEntry, AnalysisGroup, AnalysisSide, JournalFilters } from '../../types/accounting';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { DatePicker } from '../ui/DatePicker';
import { JournalLines } from './JournalAudit';
import { AccountingHistory } from './AccountingManagement';

const TransitDetails = lazy(() => import('../logistics/TransitCostsModal').then(m => ({ default: m.TransitCostsModal })));
const CustomerDetails = lazy(() => import('../customers/CustomerDetailsModal').then(m => ({ default: m.CustomerDetailsModal })));
const SaleDetails = lazy(() => import('../transactions/TransactionDetailsModal').then(m => ({ default: m.TransactionDetailsModal })));
const PurchaseDetails = lazy(() => import('../purchases/UpdatePurchaseModal').then(m => ({ default: m.UpdatePurchaseModal })));
const ProductDetails = lazy(() => import('../inventory/ProductHistoryModal').then(m => ({ default: m.ProductHistoryModal })));
const StoveDetails = lazy(() => import('../inventory/StoveInventory').then(m => ({ default: m.StoveProductDialog })));
const EmployeeProfile = lazy(() => import('../employees/EmployeeProfile').then(m => ({ default: m.EmployeeProfileDialog })));

export function AccountingBreakdownModal({ title, filters, group, side, expected, onClose }: { title: string; filters: JournalFilters; group: AnalysisGroup; side: AnalysisSide; expected: number; onClose: () => void }) {
 const [mode, setMode] = useState<'components' | 'history'>('components'); const [page, setPage] = useState(0); const [search, setSearch] = useState(''); const [account, setAccount] = useState(''); const [entity, setEntity] = useState<string | null>(null); const [historyFrom, setHistoryFrom] = useState('');
 const [component, setComponent] = useState<{ type_id: string; business: string } | null>(null);
 const [record, setRecord] = useState<AccountingBreakdownEntry | null>(null); const deferredSearch = useDeferredValue(search);
 const q = useAccountingBreakdown({ ...filters, search: deferredSearch, account, entity_id: entity ?? '', history_from: historyFrom, type_id: component?.type_id, component_business: component?.business }, group, side, mode, page);
 const { profile, can } = useAuth();
 const changeMode = (m: 'components' | 'history') => { setMode(m); setPage(0); };
 function canOpen(row: AccountingBreakdownEntry) {
  if (profile?.tenant_id !== row.tenant_id || !row.record_id) return false;
  return row.record_kind === 'financial_entry' ? can('finance:view') || can('finance:manage') : row.record_kind === 'transit' ? can('logistics:view') || can('logistics:manage') : row.record_kind === 'customer' ? can('customers:view') || can('customers:manage') : row.record_kind === 'sale' ? can('sales:view') || can('dashboard:view') : row.record_kind === 'purchase' ? can('purchases:view') || can('purchases:manage') : row.record_kind === 'product' ? can('inventory:view') || can('inventory:manage') : row.record_kind === 'employee' ? can('employees:view') || can('employees:manage') : row.record_kind === 'loan' || row.record_kind === 'asset';
 }
 return <><PurchaseDialog className="financial-breakdown-dialog" title={title} subtitle={side === 'period' ? `${filters.from} — ${filters.to}` : q.data ? `${q.data.original_opening ? 'Original opening' : 'Financial position through'} ${q.data.cutoff} · Asia/Dhaka` : 'Loading historical cutoff…'} onClose={onClose}>
  <div className="modal-body accounting-drilldown"><div className="breakdown-balance"><span>{side === 'period' ? 'Period total' : entity ? 'Component balance' : 'Balance at cutoff'}</span><strong>{formatBDT(q.data?.balance ?? expected)}</strong></div>
   <nav className="accounting-tabs" aria-label="Breakdown view"><button aria-current={mode === 'components' ? 'page' : undefined} onClick={() => changeMode('components')}>Components</button><button aria-current={mode === 'history' ? 'page' : undefined} onClick={() => changeMode('history')}>Historical activity</button></nav>
   <div className="breakdown-filters"><label className="input-group"><span className="input-label">Search {mode === 'components' ? 'components' : 'activity'}</span><input className="input-field" value={search} placeholder="Name, description or reference" onChange={e => { setSearch(e.target.value); setPage(0); }} /></label>{mode === 'history' && <div className="input-group"><span className="input-label">Activity from (optional)</span><DatePicker label="Activity from" value={historyFrom} max={q.data?.cutoff} onChange={v => { setHistoryFrom(v); setPage(0); }} /></div>}</div>
   {entity && <button className="btn btn-secondary" onClick={() => { setEntity(null); setAccount(''); setComponent(null); setPage(0); }}>Show all components</button>}
   {q.isPending && <p role="status">Loading breakdown…</p>}{q.error && <p role="alert" className="payment-error">{q.error.message}<button className="btn btn-secondary" onClick={() => void q.refetch()}>Retry</button></p>}
   {q.data && <><p className="finance-note">{mode === 'components' ? '' : `Matching movement total: ${formatBDT(q.data.filtered_movement ?? 0)}. Without activity filters, these movements explain the displayed balance.`}</p>
    {q.data.entries.map((row, index) => <article className="breakdown-entry" key={row.journal_id ? `${row.tenant_id}:${row.journal_id}:${row.line_no}` : `${row.tenant_id}:${row.account}:${row.type_id}:${row.business_category}:${row.entity_id ?? index}`}><header><div><strong>{mode === 'history' ? row.description : `${row.type_name ?? row.entity_name} · ${businessLines.filter(b => b === row.business_category).map(b => businessNames[b]).join('')}`}</strong><small>{row.name}{row.entity_id ? ` · ${row.entity_name}` : ''}{mode === 'history' ? ` · ${row.occurred_on} · ${row.source?.replaceAll('_', ' ')}` : ''}{row.estimated ? ' · Development estimate' : ''}</small></div><b>{formatBDT(row.amount)}</b></header>
     <div className="breakdown-actions">{mode === 'components' && <button className="btn btn-secondary" onClick={() => { setEntity(row.entity_id ?? 'none'); setAccount(row.account); setComponent({ type_id: row.type_id, business: row.business_category }); setSearch(''); changeMode('history'); }}>Activity</button>}{canOpen(row) && <button className="btn btn-secondary" onClick={() => setRecord(row)}>Open current record</button>}{mode === 'history' && row.source === 'sale' && row.source_id && profile?.tenant_id === row.tenant_id && (can('sales:view') || can('dashboard:view')) && <button className="btn btn-secondary" onClick={() => setRecord({ ...row, record_kind: 'sale', record_id: row.source_id ?? null })}>Open sale</button>}</div>
     {row.journal_id && <BreakdownJournal filters={filters} id={row.journal_id} reference={row.transaction_reference ?? row.source_id ?? ''} />}
    </article>)}{!q.data.total && <p className="finance-empty">No matching {mode === 'components' ? 'outstanding components' : 'activity'} at this cutoff.</p>}
    <Pagination page={page} pageSize={20} total={q.data.total} onChange={setPage} busy={q.isFetching || deferredSearch !== search} label={mode === 'components' ? 'components' : 'movements'} alwaysVisible />
   </>}
  </div><div className="modal-footer"><button className="btn btn-secondary" onClick={onClose}>Close</button></div>
 </PurchaseDialog>{record && <Suspense fallback={<PurchaseDialog title="Loading record" onClose={() => setRecord(null)}><div className="modal-body" role="status">Loading…</div></PurchaseDialog>}><RelatedRecord record={record} onClose={() => setRecord(null)} /></Suspense>}</>;
}
function BreakdownJournal({ filters, id, reference }: { filters: JournalFilters; id: string; reference: string }) {
 const [open, setOpen] = useState(false);
 return <details className="breakdown-journal" onToggle={e => setOpen(e.currentTarget.open)}><summary>Journal evidence</summary>{open && <><p className="finance-note journal-reference">Source reference: {reference}</p><JournalLines filters={filters} id={id} /></>}</details>;
}
export function RelatedRecord({ record, onClose }: { record: AccountingBreakdownEntry; onClose: () => void }) {
 const id = record.record_id ?? '';
 if (record.record_kind === 'financial_entry') return <FinancialEntryDetails id={id} onClose={onClose} />;
 if (record.record_kind === 'transit') return <RelatedTransit id={id} onClose={onClose} />;
 if (record.record_kind === 'customer') return <CustomerDetails customerId={id} onClose={onClose} />;
 if (record.record_kind === 'sale') return <SaleDetails saleId={id} onClose={onClose} />;
 if (record.record_kind === 'loan' || record.record_kind === 'asset') return <AccountingHistory kind={record.record_kind} id={id} onClose={onClose} />;
 if (record.record_kind === 'purchase') return <RelatedPurchase id={id} onClose={onClose} />;
 if (record.record_kind === 'employee') return <RelatedEmployee id={id} onClose={onClose} />;
 return <RelatedProduct id={id} onClose={onClose} />;
}
function RelatedEmployee({ id, onClose }: { id: string; onClose: () => void }) {
 const overview = useEmployeeOverview(); const operation = useEmployeeOperation();
 return <EmployeeProfile id={id} types={overview.data?.types ?? []} operation={operation} onClose={onClose} />;
}
function RelatedPurchase({ id, onClose }: { id: string; onClose: () => void }) {
 const q = usePurchaseDetails(id);
 return q.data ? <PurchaseDetails purchase={q.data} open onClose={onClose} /> : <PurchaseDialog title="Purchase" onClose={onClose}><div className="modal-body">{q.error ? <p role="alert">{q.error.message}</p> : <p role="status">Loading purchase…</p>}</div></PurchaseDialog>;
}
function RelatedProduct({ id, onClose }: { id: string; onClose: () => void }) {
 const q = useAccountingProduct(id);
 if (q.data?.business_category === 'lpg') return <ProductDetails item={q.data} onClose={onClose} />;
 if (q.data?.business_category === 'stove') return <StoveDetails product={q.data} onClose={onClose} />;
 return <PurchaseDialog title="Product" onClose={onClose}><div className="modal-body">{q.error ? <p role="alert">{q.error.message}</p> : <p role="status">Loading product…</p>}</div></PurchaseDialog>;
}
export function AccountingHealth({ filters }: { filters: JournalFilters }) {
 const [page, setPage] = useState(0); const q = useAccountingHealth(filters, page);
 return <section className="accounting-card">{q.isPending && <p role="status">Loading reconciliation…</p>}{q.error && <p role="alert">{q.error.message}</p>}{q.data && <><p>{q.data.snapshots} valid month-end savepoints · {q.data.pending} records queued for verification</p><p className="finance-note">Changed records run at approximately 3:00 AM Asia/Dhaka. Weekly checks and month-end validation use resumable batches. Financial transactions remain authoritative.</p>{q.data.entries.map(e => <details className="breakdown-entry" key={e.finding_id}><summary>{e.kind} · {e.status} · {e.recorded_at.slice(0, 10)}</summary><p>{e.diagnostic}</p><p className="journal-reference">Record: {e.entity_id}</p><div className="accounting-table-wrap"><table><thead><tr><th>Measure</th><th>Observed</th><th>Expected</th></tr></thead><tbody>{[...new Set([...Object.keys(e.observed), ...Object.keys(e.expected)])].map(k => <tr key={k}><td>{k}</td><td>{String(e.observed[k] ?? '—')}</td><td>{String(e.expected[k] ?? '—')}</td></tr>)}</tbody></table></div></details>)}{!q.data.total && <p>No recorded discrepancies.</p>}<Pagination page={page} pageSize={20} total={q.data.total} onChange={setPage} label="reconciliation findings" /></>}</section>;
}

function RelatedTransit({ id, onClose }: { id: string; onClose: () => void }) { const q = useTransit(id); return q.data ? <TransitDetails open transit={q.data} onClose={onClose} /> : <PurchaseDialog title="Transit" onClose={onClose}><div className="modal-body">{q.error?.message ?? "Loading transit…"}</div></PurchaseDialog>; }
