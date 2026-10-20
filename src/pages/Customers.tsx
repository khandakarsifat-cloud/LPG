import { useDeferredValue, useState } from 'react';
import { Box, Clock3, Droplets, MapPin, Phone, Plus, RotateCcw, Search, SlidersHorizontal, X } from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { useCustomerDirectory, useCustomerOverview } from '../hooks/useCustomerDirectory';
import { useGridPageSize } from '../hooks/useListPage';
import { customerActivityFilterCount, customerDay, customerDisplayName, defaultCustomerFilters } from '../lib/customer';
import { formatBDQty } from '../lib/formatBDT';
import { PurchaseSelect } from '../components/purchases/PurchaseControls';
import { Pagination } from '../components/ui/Pagination';
import { CustomerFormModal } from '../components/customers/CustomerFormModal';
import { CustomerDetailsModal } from '../components/customers/CustomerDetailsModal';
import { CustomerFiltersModal } from '../components/customers/CustomerFiltersModal';
import type { CustomerFilters, CustomerSummary } from '../types/customer';
import '../components/customers/customers.css';

export const CustomersPage = () => {
  const { can } = useAuth();
  const [filters, setFilters] = useState(defaultCustomerFilters); const deferred = useDeferredValue(filters);
  const { anchor, pageSize } = useGridPageSize();
  const [position, setPosition] = useState({ page: 0, size: pageSize });
  const page = position.size === pageSize ? position.page : 0;
  const setPage = (next: number) => setPosition({ page: next, size: pageSize });
  const [add, setAdd] = useState(false); const [advanced, setAdvanced] = useState(false);
  const [customerId, setCustomerId] = useState<string | null>(null);
  const [selectedCustomer, setSelectedCustomer] = useState<CustomerSummary>();
  const overview = useCustomerOverview(); const query = useCustomerDirectory(deferred, page, pageSize);
  const set = (next: CustomerFilters) => { setFilters(next); setPage(0); };
  const reset = () => set(defaultCustomerFilters);
  const count = customerActivityFilterCount(filters);
  const hasFilters = Boolean(filters.search || filters.tier !== 'all' || filters.sort !== 'name_asc' || count);
  const metric = (value: number | undefined) => overview.isPending ? '…' : overview.isError ? '—' : formatBDQty(value ?? 0);
  const scope = deferred.from || deferred.to || deferred.item_ids !== null;
  return <div className="customers-page">
    <div className="customer-overview-row"><div className="customer-overview" aria-label="Customer overview">
      <div className="customer-metric"><span>Wholesale customers</span><strong>{metric(overview.data?.wholesale)}</strong></div>
      <div className="customer-metric"><span>Retail customers</span><strong>{metric(overview.data?.retail)}</strong></div>
      <div className="customer-metric fresh" title={overview.data ? `Since Saturday ${overview.data.week_start}, Bangladesh time` : undefined}><span>New this week</span><div className="customer-metric-pair"><div><strong>{metric(overview.data?.new_wholesale)}</strong><span>Wholesale</span></div><div><strong>{metric(overview.data?.new_retail)}</strong><span>Retail</span></div></div></div>
      <div className="customer-metric inactive" title={overview.data ? `No completed transactions since ${overview.data.inactive_since}. Includes older customers who have never bought.` : undefined}><span>No transactions in 2 months</span><div className="customer-metric-pair"><div><strong>{metric(overview.data?.inactive_wholesale)}</strong><span>Wholesale</span></div><div><strong>{metric(overview.data?.inactive_retail)}</strong><span>Retail</span></div></div></div>
    </div>{can('customers:manage') && <button className="btn btn-primary customer-add" aria-label="Add customer" onClick={() => setAdd(true)}><Plus size={16} /><span>Add customer</span></button>}</div>
    {overview.isError && <p role="alert" className="purchase-error">Customer overview could not be loaded. <button className="btn btn-secondary" onClick={() => void overview.refetch()}>Retry overview</button></p>}
    <div className="customer-toolbar filter-toolbar" data-filtered={hasFilters} aria-label="Customer filters"><div className="customer-toolbar-main">
      <div className="input-group customer-search"><label className="input-label" htmlFor="customer-search">Search customers <span id="customer-search-help">Spaces = AND · Commas = OR</span></label><div className="customer-search-field"><Search size={16} /><input id="customer-search" aria-describedby="customer-search-help" className="input-field" placeholder="Name, shop, number or address…" maxLength={500} value={filters.search} onChange={event => set({ ...filters, search: event.target.value })} /></div></div>
      <PurchaseSelect label="Customer type" value={filters.tier} options={[{ value: 'all', label: 'All types' }, { value: 'wholesale', label: 'Wholesale' }, { value: 'retail', label: 'Retail' }]} onChange={value => { if (value === 'all' || value === 'retail' || value === 'wholesale') set({ ...filters, tier: value }); }} />
      <PurchaseSelect label="Sort by" value={filters.sort} options={[{ value: 'name_asc', label: 'Name: A to Z' }, { value: 'name_desc', label: 'Name: Z to A' }, { value: 'sold_desc', label: 'Total sold: high to low' }, { value: 'sold_asc', label: 'Total sold: low to high' }]} onChange={value => { if (value === 'name_asc' || value === 'name_desc' || value === 'sold_asc' || value === 'sold_desc') set({ ...filters, sort: value }); }} />
      <button className={`btn btn-secondary customer-advanced${count ? ' active' : ''}`} onClick={() => setAdvanced(true)}><SlidersHorizontal size={15} />Advanced filters{count > 0 ? ` · ${count}` : ''}</button>
    </div><p className="customer-search-example">Try <strong>mirpur rahman, uttara</strong> to find Mirpur + Rahman together, or anyone in Uttara.</p>
      {hasFilters && <div className="customer-active-filters">
        {(filters.from || filters.to) && <button onClick={() => set({ ...filters, from: '', to: '' })}>{filters.from || 'Start'} – {filters.to || 'Today'}<X size={12} /></button>}
        {filters.item_ids !== null && <button onClick={() => set({ ...filters, item_ids: null })}>{filters.item_ids.length} products<X size={12} /></button>}
        {(['transactions', 'refill', 'package'] as const).filter(key => filters[`${key}_min`] || filters[`${key}_max`]).map(key => <button key={key} onClick={() => set({ ...filters, [`${key}_min`]: '', [`${key}_max`]: '' })}>{key === 'transactions' ? 'Transactions' : key === 'refill' ? 'Refills' : 'Packages'}: {filters[`${key}_min`] || '0'}–{filters[`${key}_max`] || '∞'}<X size={12} /></button>)}
        <button className="customer-clear" onClick={reset}><RotateCcw size={12} />Clear all</button>
      </div>}
    </div>
    <div className="customer-directory-heading"><h2>Customer directory <span>{query.data ? formatBDQty(query.data.total) : ''}</span></h2><small>Total sold: {scope ? `${deferred.from || 'Start'} – ${deferred.to || 'Today'} · ${deferred.item_ids === null ? 'all products' : `${deferred.item_ids.length} products`}` : 'all time, all products'}</small></div>
    <div className="customer-directory-pages"><Pagination page={page} pageSize={pageSize} total={query.data?.total ?? 0} label="customers" onChange={setPage} busy={query.isFetching} alwaysVisible /></div>
    <div className="directory-page-anchor" ref={anchor} />
    {query.isPending && <div className="customer-empty" role="status">Loading customers…</div>}
    {query.isError && <div className="purchase-error" role="alert">Customers could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></div>}
    {query.data && <div aria-busy={query.isFetching}><div className="customer-grid">{query.data.entries.map(customer => {
      const inactive = overview.data && new Date(customer.last_transaction_at || customer.created_at) < new Date(`${overview.data.inactive_since}T00:00:00+06:00`);
      return <button className="customer-card" key={customer.customer_id} onClick={() => { setSelectedCustomer(customer); setCustomerId(customer.customer_id); }} aria-label={`Open ${customerDisplayName(customer)}`}>
        <span className="customer-card-heading"><span><strong>{customerDisplayName(customer)}</strong>{customer.tier === 'wholesale' && customer.shop_name && <small>{customer.name}</small>}</span><span className={`customer-badge ${customer.tier}`}>{customer.tier === 'wholesale' ? 'Wholesale' : 'Retail'}</span></span>
        <span className="customer-card-contact"><Phone size={13} />{customer.phone}</span><span className="customer-card-contact"><MapPin size={13} />{customer.address || 'No address saved'}</span>
        <span className="customer-card-sales"><span className="customer-card-total"><span>Total sold</span><strong>{formatBDQty(customer.total_sold)}<small>cylinders</small></strong></span><span className="customer-card-split"><span><Droplets size={12} /><b>{formatBDQty(customer.refill)}</b> refill</span><span><Box size={12} /><b>{formatBDQty(customer.package)}</b> package</span></span></span>
        <span className={`customer-last-transaction${inactive ? ' inactive' : ''}`}><Clock3 size={11} />{inactive ? 'No transactions for 2+ months' : customer.last_transaction_at ? `Last transaction ${customerDay(customer.last_transaction_at)}` : 'No transactions yet'}</span>
      </button>;
    })}</div>
      {!query.data.entries.length && <div className="customer-empty"><Search size={28} /><h3>{hasFilters ? 'No customers match these filters' : query.data.total ? 'No customers on this page' : 'No customers yet'}</h3><p>{hasFilters ? 'Try another name, number or area, or clear your filters.' : 'Add a customer to start tracking their sales history.'}</p>{page > 0 ? <button className="btn btn-secondary" onClick={() => setPage(0)}>Go to first page</button> : hasFilters ? <button className="btn btn-secondary" onClick={reset}>Clear search and filters</button> : null}</div>}

    </div>}
    {add && <CustomerFormModal onClose={() => setAdd(false)} onSaved={saved => { set(defaultCustomerFilters); setSelectedCustomer(undefined); setCustomerId(saved.customer_id); }} />}
    {advanced && <CustomerFiltersModal filters={filters} onClose={() => setAdvanced(false)} onApply={set} />}
    {customerId && <CustomerDetailsModal customerId={customerId} preview={selectedCustomer?.customer_id === customerId ? selectedCustomer : undefined} onClose={() => setCustomerId(null)} />}
  </div>;
};
