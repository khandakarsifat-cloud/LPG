import { useDeferredValue, useState } from 'react';
import toast from 'react-hot-toast';
import { Calendar, Plus, ReceiptText, RotateCcw, Search } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import { defaultSalesFilters, useCollectBottles, useSalesDirectory, useSalesOverview } from '../hooks/useSales';
import { useGridPageSize } from '../hooks/useListPage';
import { formatBDT } from '../lib/formatBDT';
import { PurchaseSelect } from '../components/purchases/PurchaseControls';
import { DatePicker } from '../components/ui/DatePicker';
import { Pagination } from '../components/ui/Pagination';
import { CardProductPreview } from '../components/ui/CardProductPreview';
import { DirectorySort } from '../components/ui/DirectorySort';
import { TransactionDetailsModal } from '../components/transactions/TransactionDetailsModal';
import '../components/purchases/purchases.css';
import './sales.css';

export function SalesPage() {
 const { can } = useAuth(); const [filters,setFilters] = useState(defaultSalesFilters); const [saleId,setSaleId] = useState<string | null>(null);
 const overview = useSalesOverview(); const search = useDeferredValue(filters.search); const applied = { ...filters, search };
 const recovery = useCollectBottles();
 const { grid,pageSize } = useGridPageSize();
 const query = useSalesDirectory(applied,pageSize); const { page,setPage } = query; const total = query.data?.total ?? 0;
 const filtered = JSON.stringify(filters) !== JSON.stringify(defaultSalesFilters);
 const patch = (field: keyof typeof filters,value: string) => setFilters(current => ({ ...current,[field]: value }));
 const metric = (value: string | number) => overview.isPending ? '…' : overview.isError ? '—' : value;
 return <div className="purchases-page sales-page">
  <div className="page-header purchases-header"><dl className="purchase-list-summary" aria-label="Sales overview">
   <div><dt>Sales</dt><dd>{metric(overview.data?.total ?? 0)}</dd></div><div><dt>Total billed</dt><dd>{metric(formatBDT(overview.data?.amount ?? 0))}</dd></div>
   <div><dt>Money due</dt><dd>{metric(formatBDT(overview.data?.due ?? 0))}</dd></div><div><dt>Bottles due</dt><dd>{metric(overview.data?.bottles ?? 0)}</dd></div>
  </dl>{can('pos:sell') && <div className="purchases-header-actions"><Link to="/pos" className="btn btn-primary" aria-label="New sale"><Plus size={15} /><span className="purchase-new-label">New sale</span></Link></div>}</div>
  {overview.isError && <p role="alert" className="purchase-error">Sales overview could not be loaded. <button className="btn btn-secondary" onClick={() => void overview.refetch()}>Retry overview</button></p>}
  {recovery.hasPending && <div className="finance-recovery" role="alert">A previous bottle collection needs confirmation.<button className="btn btn-secondary" disabled={recovery.isPending} onClick={async () => { try { await recovery.mutateAsync(undefined); toast.success('Previous bottle collection confirmed'); } catch { /* show recovery error */ } }}>Recover bottle collection</button></div>}
  {recovery.error && <p className="payment-error" role="alert">{recovery.error.message}</p>}
  <div className="purchase-list-panel purchases-list">
   <div className="purchase-toolbar purchase-toolbar-business filter-toolbar" data-filtered={filtered} aria-label="Sales filters">
    <div className="input-group purchase-search-group"><label className="input-label" htmlFor="sales-search">Search sales <span id="sales-search-help">Spaces = AND · Commas = OR</span></label><div className="purchase-search"><Search size={16} className="topbar-search-icon" /><input id="sales-search" className="input-field topbar-search-input" maxLength={500} value={filters.search} aria-describedby="sales-search-help" placeholder="Customer, phone, product, receipt, note…" onChange={e => patch('search',e.target.value)} /></div></div>
    <PurchaseSelect label="Status" value={filters.status} onChange={v => patch('status',v)} options={[{value:'all',label:'All statuses'},{value:'outstanding',label:'Any money due'},{value:'unpaid',label:'Unpaid'},{value:'partial',label:'Part paid'},{value:'paid',label:'Paid'},{value:'cancelled',label:'Cancelled'}]} />
    <PurchaseSelect label="Bottle status" value={filters.bottles} onChange={v => patch('bottles',v)} options={[{value:'all',label:'All bottles'},{value:'outstanding',label:'Any bottles due'},{value:'partial',label:'Part received'},{value:'none_received',label:'None received'},{value:'received',label:'Fully settled'}]} />
    <PurchaseSelect label="Business" value={filters.business_category} onChange={v => { if (v === 'all' || v === 'lpg' || v === 'stove') patch('business_category',v); }} options={[{value:'all',label:'Both businesses'},{value:'lpg',label:'LPG'},{value:'stove',label:'Stove'}]} />
    <div className="purchase-filter-extras">
     <div className="purchase-date-range" role="group" aria-label="Sale date range"><label htmlFor="sales-from">From</label><DatePicker id="sales-from" label="From" value={filters.from} max={filters.to || undefined} onChange={v => patch('from',v)} /><label htmlFor="sales-to">To</label><DatePicker id="sales-to" label="To" value={filters.to} min={filters.from || undefined} onChange={v => patch('to',v)} /></div>
     <PurchaseSelect label="Sale type" value={filters.tier} onChange={v => patch('tier',v)} options={[{value:'all',label:'All sale types'},{value:'retail',label:'Retail'},{value:'wholesale',label:'Wholesale'}]} />
     <DirectorySort value={filters.sort} onChange={v => patch('sort',v)} options={[{label:'Sale date',asc:'date_asc',desc:'date_desc'},{label:'Total billed',asc:'amount_asc',desc:'amount_desc'},{label:'Money due',asc:'due_asc',desc:'due_desc'},{label:'Bottles due',asc:'bottles_asc',desc:'bottles_desc'},{label:'Customer name',asc:'customer_asc',desc:'customer_desc'}]} />
     <button className="btn btn-ghost" disabled={!filtered} onClick={() => setFilters(defaultSalesFilters)}><RotateCcw size={14} />Clear filters</button>
    </div>
   </div>
   {query.isError && <p role="alert" className="purchase-error">Sales could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
   <div className="purchase-results-heading"><h2>Sales <span>{total}</span></h2><Pagination page={query.data?.page ?? page} pageSize={query.data?.pageSize ?? pageSize} total={total} onChange={setPage} busy={query.isFetching || search !== filters.search} label="sales" alwaysVisible /></div>
   {query.isPending && <div role="status" className="purchase-empty">Loading sales…</div>}
   {query.isSuccess && !query.data?.entries.length && <div className="purchase-empty"><ReceiptText size={28} /><p>{filtered ? 'No sales match these filters.' : 'Saved POS sales appear here.'}</p>{page>0 && <button className="btn btn-secondary" onClick={() => setPage(0)}>Go to first page</button>}</div>}
   <div className="purchases-grid sales-grid adaptive-grid" ref={grid} aria-busy={query.isFetching}>{query.data?.entries.map(sale => <button className="glass-panel purchase-card sale-card record-card" key={sale.sale_id} onClick={() => setSaleId(sale.sale_id)} data-sale-id={sale.sale_id}>
    <div className="purchase-card-header"><div><strong>{sale.sale_tier === 'wholesale' && sale.shop_name ? sale.shop_name : sale.name}</strong><small>{sale.phone} · {sale.sale_tier} · {sale.business_category === 'stove' ? 'Stove' : 'LPG'}</small></div></div>
    <div className="record-statuses"><span className={`purchase-badge ${sale.status==='voided'?'transit-cancelled':`payment-${sale.due===0?'paid':sale.paid_amount>0?'partial':'unpaid'}`}`}>{sale.status==='voided'?'Cancelled':sale.due===0?'Paid':sale.paid_amount>0?'Part paid':'Unpaid'}</span>{sale.business_category !== 'stove' && sale.status !== 'voided' && <span className={`purchase-badge ${sale.outstanding_bottles>0?'payment-partial':'payment-paid'}`}>{!sale.expected ? 'No bottle returns' : sale.outstanding_bottles===0 ? 'Bottles settled' : `${sale.received_bottles>0?'Part received':'None received'} · ${sale.outstanding_bottles} due`}</span>}</div>
    <div className="purchase-card-meta"><div className="purchase-info-row"><Calendar size={14} /><time>{new Date(sale.created_at).toLocaleDateString('en-BD',{timeZone:'Asia/Dhaka',day:'numeric',month:'short',year:'numeric'})}</time></div><small>#{sale.sale_id.slice(0,8).toUpperCase()}</small></div>
    <CardProductPreview label="Sold products">{sale.items.filter(i => i.type !== 'empty_return').map(i => <div className="purchase-item-pill" key={`${i.item_id}:${i.type}`}><span className="pill-qty">{i.quantity}×</span><span className="pill-name">{i.name}{sale.business_category !== 'stove' && ` · ${i.type === 'package' ? 'Package' : 'Refill'}`}</span></div>)}</CardProductPreview>
    <div className="sale-money"><span>Paid <strong>{formatBDT(sale.paid_amount)}</strong></span><span>{sale.status === 'voided' ? 'Refund due' : 'Due'} <strong>{formatBDT(sale.status === 'voided' ? sale.refund_due ?? 0 : sale.due)}</strong></span></div>
    <div className="purchase-card-footer"><span className="purchase-total-label">Total billed{sale.additional_charges>0?' · includes later fees':''}</span><strong className="purchase-total-value">{formatBDT(sale.total_amount)}</strong></div>
   </button>)}</div>
  </div>
  {saleId && <TransactionDetailsModal saleId={saleId} onClose={() => setSaleId(null)} returnLabel="Back to Sales" />}
 </div>;
}
