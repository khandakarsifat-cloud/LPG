import { useMemo, useState } from 'react';
import type { UseQueryResult } from '@tanstack/react-query';
import { Package, Truck, Calendar, Search, ArrowRight, RotateCcw } from 'lucide-react';
import { filterPurchases, type PurchaseSort } from '../../lib/purchase';
import { PurchaseSelect, PurchaseStatuses } from './PurchaseControls';
import { UpdatePurchaseModal } from './UpdatePurchaseModal';
import { formatBDT } from '../../lib/formatBDT';
import { PURCHASE_STATUS_LABELS, type Purchase } from '../../types/purchase';
import './purchases.css';

export function PurchasesList({ query }: { query: UseQueryResult<Purchase[], Error> }) {
  const purchases = query.data ?? [];
  const [selected, setSelected] = useState<Purchase | null>(null);
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState('all');
  const [payment, setPayment] = useState('all');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [sort, setSort] = useState<PurchaseSort>('date_desc');
  const hasFilters = search.trim() !== '' || status !== 'all' || payment !== 'all' || from !== '' || to !== '' || sort !== 'date_desc';
  const resetFilters = () => { setSearch(''); setStatus('all'); setPayment('all'); setFrom(''); setTo(''); setSort('date_desc'); };
  const filtered = useMemo(() => filterPurchases(query.data ?? [], { search, status, payment, from, to, sort }), [query.data, search, status, payment, from, to, sort]);
  if (query.isLoading) return <div className="purchase-empty">Loading purchases…</div>;
  if (query.isError) return <p role="alert" className="purchase-error">Purchases could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>;
  return <div className="purchases-list">
    <div className="purchase-toolbar">
      <div className="input-group purchase-search-group"><label className="input-label" htmlFor="purchase-search">Search purchases <span aria-hidden="true" id="purchase-search-help">Spaces = AND · Commas = OR</span></label><div className="purchase-search">
        <Search size={16} className="topbar-search-icon" /><input id="purchase-search" className="input-field topbar-search-input" aria-label="Search purchases" aria-describedby="purchase-search-help" placeholder="Company, plant, product, 22mm, 12kg, vehicle…" value={search} onChange={event => setSearch(event.target.value)} />
      </div></div>
      <PurchaseSelect label="Purchase status" value={status} onChange={setStatus} options={[{ value: 'all', label: 'All statuses' }, ...Object.entries(PURCHASE_STATUS_LABELS).map(([value,label]) => ({ value,label }))]} />
      <PurchaseSelect label="Payment status" value={payment} onChange={setPayment} options={[{ value: 'all', label: 'All payments' }, { value: 'unpaid', label: 'Unpaid' }, { value: 'paid', label: 'Paid' }]} />
      <div className="purchase-filter-extras">
        <div className="purchase-date-range" role="group" aria-label="Purchase date range">
          <label htmlFor="purchase-from">From</label><input id="purchase-from" className="input-field" type="date" value={from} max={to || undefined} onChange={event => setFrom(event.target.value)} />
          <label htmlFor="purchase-to">To</label><input id="purchase-to" className="input-field" type="date" value={to} min={from || undefined} onChange={event => setTo(event.target.value)} />
        </div>
        <PurchaseSelect label="Sort by" value={sort} onChange={value => {
          if (value === 'date_desc' || value === 'date_asc' || value === 'amount_desc' || value === 'amount_asc') setSort(value);
        }} options={[{ value: 'date_desc', label: 'Date: newest first' }, { value: 'date_asc', label: 'Date: oldest first' }, { value: 'amount_desc', label: 'Total: highest first' }, { value: 'amount_asc', label: 'Total: lowest first' }]} />
        <button type="button" className="btn btn-ghost" disabled={!hasFilters} onClick={resetFilters}><RotateCcw size={14} /> Clear filters</button>
      </div>
    </div>
    <div className="purchase-results-heading"><h2>Purchase orders <span>{filtered.length}{hasFilters ? ` of ${purchases.length}` : ''}</span></h2>
    </div>
    {!filtered.length && <div className="purchase-empty purchase-list-empty"><Package size={28} /><p>{purchases.length ? 'No purchases match these filters.' : 'Create a purchase with a destination plant to get started.'}</p>
      {hasFilters && <button className="btn btn-secondary" onClick={resetFilters}>Clear filters</button>}
    </div>}
    <div className="purchases-grid">{filtered.map(purchase => <button key={purchase.purchase_id} className="glass-panel purchase-card purchase-card-button" onClick={() => setSelected(purchase)}>
      <div className="purchase-card-header"><div><strong>{purchase.plant_name}</strong><p className="purchase-hint">{purchase.company_name ?? 'Historical purchase'}</p></div><PurchaseStatuses purchase={purchase} /></div>
      <div className="purchase-card-meta"><div className="purchase-info-row"><Calendar size={14} /><span>{new Date(purchase.created_at).toLocaleDateString('en-BD', { timeZone: 'Asia/Dhaka', day: 'numeric', month: 'short', year: 'numeric' })}</span></div>
        <div className="purchase-info-row"><Truck size={14} /><span>{purchase.truck_name ?? 'Truck not assigned'}</span></div></div>
      <div className="purchase-items-preview"><div className="purchase-items-count">{purchase.items.length} product {purchase.items.length === 1 ? 'line' : 'lines'}</div>
        {!purchase.items.length && <p className="purchase-hint">Add products before dispatch.</p>}
        <div className="purchase-items-list">{purchase.items.slice(0, 3).map(item => <div key={item.purchase_item_id} className="purchase-item-pill">
          <span className="pill-qty">{purchase.status === 'received' ? item.received_quantity ?? item.quantity : item.quantity}×</span><span className="pill-name">{item.size_kg} kg {item.mouth_size} {item.type === 'refill' ? 'refills' : 'new cylinders'}</span>
        </div>)}{purchase.items.length > 3 && <span className="purchase-item-pill more">+{purchase.items.length - 3} more</span>}</div></div>
      <div className="purchase-card-footer"><div><span className="purchase-total-label">Company payable</span><div>{formatBDT(Number(purchase.company_payable))}</div></div>
        <div><span className="purchase-total-label">Total purchase cost</span><div className="purchase-total-value">{formatBDT(Number(purchase.total_cost))}</div></div></div>
      <div className="purchase-card-action"><span>{purchase.status === 'received' && purchase.payment_status === 'paid' ? 'View summary' : 'View purchase'}</span><ArrowRight size={15} aria-hidden="true" /></div>
    </button>)}</div>
    <UpdatePurchaseModal open={selected !== null} purchase={selected} onClose={() => setSelected(null)} />
  </div>;
}
