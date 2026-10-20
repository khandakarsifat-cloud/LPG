import { useGridPageSize } from '../../hooks/useListPage';
import { DatePicker } from '../ui/DatePicker';
import { useDeferredValue, useState } from 'react';
import { Package, Truck, Calendar, Search, RotateCcw } from 'lucide-react';
import { type PurchaseSort } from '../../lib/purchase';
import { usePurchaseDirectory } from '../../hooks/usePurchases';
import { PurchaseSelect, PurchaseStatuses } from './PurchaseControls';
import { UpdatePurchaseModal } from './UpdatePurchaseModal';
import { formatBDT } from '../../lib/formatBDT';
import { PURCHASE_STATUS_LABELS, type Purchase } from '../../types/purchase';
import './purchases.css';
import { Pagination } from '../ui/Pagination';

export function PurchasesList({ totalPurchases }: { totalPurchases?: number }) {
  const [selected, setSelected] = useState<Purchase | null>(null);
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState('all');
  const [payment, setPayment] = useState('all');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [sort, setSort] = useState<PurchaseSort>('date_desc');
  const hasFilters = search.trim() !== '' || status !== 'all' || payment !== 'all' || from !== '' || to !== '' || sort !== 'date_desc';
  const resetFilters = () => { setSearch(''); setStatus('all'); setPayment('all'); setFrom(''); setTo(''); setSort('date_desc'); };
  const { anchor, pageSize } = useGridPageSize(200, 10);
  const deferredSearch = useDeferredValue(search);
  const deferred = { search: deferredSearch, status, payment, from, to, sort };
  const resetKey = JSON.stringify([deferred, pageSize]);
  const [position, setPosition] = useState({ page: 0, key: resetKey });
  const page = position.key === resetKey ? position.page : 0;
  const setPage = (next: number) => setPosition({ page: next, key: resetKey });
  const query = usePurchaseDirectory(deferred, page, pageSize);
  const purchases = query.data?.entries ?? [];
  const total = query.data?.total ?? 0;
  return <div className="purchases-list">
    <div className="purchase-toolbar filter-toolbar" data-filtered={hasFilters} aria-label="Purchase filters">
      <div className="input-group purchase-search-group"><label className="input-label" htmlFor="purchase-search">Search purchases <span aria-hidden="true" id="purchase-search-help">Spaces = AND · Commas = OR</span></label><div className="purchase-search">
        <Search size={16} className="topbar-search-icon" /><input id="purchase-search" className="input-field topbar-search-input" aria-label="Search purchases" aria-describedby="purchase-search-help" placeholder="Company, plant, product, 22mm, 12kg, vehicle…" maxLength={500} value={search} onChange={event => setSearch(event.target.value)} />
      </div></div>
      <PurchaseSelect label="Purchase status" value={status} onChange={setStatus} options={[{ value: 'all', label: 'All statuses' }, ...Object.entries(PURCHASE_STATUS_LABELS).map(([value,label]) => ({ value,label }))]} />
      <PurchaseSelect label="Payment status" value={payment} onChange={setPayment} options={[{ value: 'all', label: 'All payments' }, { value: 'unpaid', label: 'Unpaid' }, { value: 'paid', label: 'Paid' }]} />
      <div className="purchase-filter-extras">
        <div className="purchase-date-range" role="group" aria-label="Purchase date range">
          <label htmlFor="purchase-from">From</label><DatePicker id="purchase-from" label="From" value={from} max={to || undefined} onChange={setFrom} />
          <label htmlFor="purchase-to">To</label><DatePicker id="purchase-to" label="To" value={to} min={from || undefined} onChange={setTo} />
        </div>
        <PurchaseSelect label="Sort by" value={sort} onChange={value => {
          if (value === 'date_desc' || value === 'date_asc' || value === 'amount_desc' || value === 'amount_asc') setSort(value);
        }} options={[{ value: 'date_desc', label: 'Date: newest first' }, { value: 'date_asc', label: 'Date: oldest first' }, { value: 'amount_desc', label: 'Total: highest first' }, { value: 'amount_asc', label: 'Total: lowest first' }]} />
        <button type="button" className="btn btn-ghost" disabled={!hasFilters} onClick={resetFilters}><RotateCcw size={14} /> Clear filters</button>
      </div>
    </div>
    {query.isError && <p role="alert" className="purchase-error">Purchases could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
    <div className="purchase-results-heading"><h2>Purchase orders <span>{total}{hasFilters && totalPurchases !== undefined ? ` of ${totalPurchases}` : ''}</span></h2>
      <Pagination page={page} pageSize={pageSize} total={total} onChange={setPage} busy={query.isFetching} label="purchases" alwaysVisible />
    </div>
    <div className="directory-page-anchor" ref={anchor} />
    {query.isPending && <div className="purchase-empty" role="status">Loading purchases…</div>}
    {query.isSuccess && !purchases.length && <div className="purchase-empty purchase-list-empty"><Package size={28} /><p>{totalPurchases ? 'No purchases match these filters.' : 'Create a purchase with a destination plant to get started.'}</p>
      {page > 0 && <button className="btn btn-secondary" onClick={() => setPage(0)}>Go to first page</button>}
      {hasFilters && <button className="btn btn-secondary" onClick={resetFilters}>Clear filters</button>}
    </div>}
    <div className="purchases-grid" aria-busy={query.isFetching}>{purchases.map(purchase => <button key={purchase.purchase_id} className="glass-panel purchase-card purchase-card-button" data-status={purchase.status} data-purchase-id={purchase.purchase_id} onClick={() => setSelected(purchase)}>
      <div className="purchase-card-header"><div><strong>{purchase.company_name ?? 'Historical purchase'}</strong></div><PurchaseStatuses purchase={purchase} /></div>
      <div className="purchase-card-meta"><div className="purchase-info-row"><Calendar size={14} /><span>{new Date(purchase.created_at).toLocaleDateString('en-BD', { timeZone: 'Asia/Dhaka', day: 'numeric', month: 'short', year: 'numeric' })}</span></div>
        <div className="purchase-info-row"><Truck size={14} /><span>{purchase.truck_name ?? 'Truck not assigned'}</span></div></div>
      {purchase.items.length > 0 && <div className="purchase-items-list" aria-label="Purchased products">
        {purchase.items.map(item => <div key={item.purchase_item_id} className="purchase-item-pill">
          <span className="pill-qty">{purchase.status === 'received' ? item.received_quantity ?? item.quantity : item.quantity}×</span>
          <span className="pill-name">{item.size_kg} kg {item.mouth_size} {item.type === 'refill' ? 'refills' : 'new cylinders'}</span>
        </div>)}
      </div>}
      <div className="purchase-card-footer"><span className="purchase-total-label">Total purchase cost</span>
        <strong className="purchase-total-value">{formatBDT(Number(purchase.total_cost))}</strong></div>
    </button>)}</div>
    <UpdatePurchaseModal open={selected !== null} purchase={purchases.find(p => p.purchase_id === selected?.purchase_id) ?? selected} onClose={() => setSelected(null)} />
  </div>;
}
