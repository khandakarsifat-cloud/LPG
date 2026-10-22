import { useDeferredValue, useState } from 'react';
import { Edit3, MapPin, Phone, ReceiptText, SlidersHorizontal, Store, UserRound } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { useCustomerProfile, useCustomerTransactions, CUSTOMER_TRANSACTION_PAGE_SIZE } from '../../hooks/useCustomerDirectory';
import { customerActivityFilterCount, customerDay, customerDisplayName, defaultCustomerFilters } from '../../lib/customer';
import { formatBDQty, formatBDT } from '../../lib/formatBDT';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { TransactionDetailsModal } from '../transactions/TransactionDetailsModal';
import { CustomerFormModal } from './CustomerFormModal';
import { CustomerFiltersModal } from './CustomerFiltersModal';
import type { CustomerSummary } from '../../types/customer';
import { useCustomerBalance } from '../../hooks/useFinance';

export function CustomerDetailsModal({ customerId, preview, onClose }: { customerId: string; preview?: CustomerSummary; onClose: () => void }) {
  const profile = useCustomerProfile(customerId, preview); const customer = profile.data ?? preview;
  const profileReady = Boolean(profile.data && !profile.isPlaceholderData);
  const { can } = useAuth(); const readable = can('sales:view') || can('receipts:print') || can('dashboard:view');
  const [filters, setFilters] = useState(defaultCustomerFilters); const deferred = useDeferredValue(filters);
  const [page, setPage] = useState(0); const [edit, setEdit] = useState(false); const [filterOpen, setFilterOpen] = useState(false);
  const [saleId, setSaleId] = useState<string | null>(null);
  const balance = useCustomerBalance(customerId, can('customers:view') || can('customers:manage') || can('finance:view') || can('finance:manage'));
  const transactions = useCustomerTransactions(customerId, deferred, page, readable);
  const reset = () => { setPage(0); setFilters(defaultCustomerFilters); };
  return <><PurchaseDialog title="Customer details" subtitle="Contact information and completed sales." className="customer-detail-dialog" onClose={onClose}>
    <div className="modal-body">
      {profile.isPending && <p className="customer-empty" role="status">Loading customer…</p>}
      {profile.isError && <p className="purchase-error" role="alert">This customer could not be loaded. <button className="btn btn-secondary" onClick={() => void profile.refetch()}>Retry</button></p>}
      {customer && <>
        <div className="customer-identity"><div className="customer-identity-main"><span className="customer-avatar">{customer.tier === 'wholesale' ? <Store size={22} /> : <UserRound size={22} />}</span><div><h3>{customerDisplayName(customer)}</h3>{customer.tier === 'wholesale' && customer.shop_name && <p>{customer.name}</p>}<span className={`customer-badge ${customer.tier}`}>{customer.tier === 'wholesale' ? 'Wholesale' : 'Retail'}</span></div></div>{can('customers:manage') && <button className="btn btn-secondary" onClick={() => setEdit(true)}><Edit3 size={14} />Edit</button>}</div>
        <div className="customer-profile-contact"><span><Phone size={14} />{customer.phone}</span><span><MapPin size={14} />{customer.address || 'No address saved'}</span></div>
        <div className="customer-profile-dates"><span>Customer since {customerDay(customer.created_at)}</span><span>Last transaction: {!profileReady ? '…' : customer.last_transaction_at ? customerDay(customer.last_transaction_at) : 'None'}</span></div>
        <div className="customer-profile-stats">{[['Transactions', formatBDQty(customer.transactions)], ['Total Sold', formatBDT(customer.total_sold_amount)], ['Refills', formatBDQty(customer.refill)], ['Packages', formatBDQty(customer.package)]].map(([label, value]) => <div key={label}><span>{label}</span><strong>{profileReady ? value : '…'}</strong></div>)}</div>
        {balance.data !== undefined && <p className="customer-notice">{balance.data < 0 ? 'Customer credit' : 'Customer outstanding'}: <strong>{formatBDT(Math.abs(balance.data))}</strong></p>}
        {balance.error && <p role="alert" className="purchase-error">Customer balance could not be loaded. <button className="btn btn-secondary" onClick={() => void balance.refetch()}>Retry</button></p>}
        <div className="customer-history-heading"><h3>Transaction history</h3><small>{filters.from || filters.to ? `${filters.from || 'Start'} – ${filters.to || 'Today'}` : 'All time'}{filters.item_ids !== null ? ` · ${filters.item_ids.length} products` : ''}</small></div>
        {readable ? <>
          <div className="customer-history-toolbar"><input className="input-field" placeholder="Search transaction or product" aria-label="Search customer transactions" value={filters.search} onChange={event => { setPage(0); setFilters(previous => ({ ...previous, search: event.target.value })); }} /><button className="btn btn-secondary" onClick={() => setFilterOpen(true)}><SlidersHorizontal size={14} />Filters{customerActivityFilterCount(filters) > 0 ? ` (${customerActivityFilterCount(filters)})` : ''}</button>{(filters.search || customerActivityFilterCount(filters) > 0) && <button className="btn btn-ghost" onClick={reset}>Clear</button>}</div>
          {transactions.isPending && <p role="status" className="customer-empty">Loading transactions…</p>}
          {transactions.isError && <p role="alert" className="purchase-error">Transactions could not be loaded. <button className="btn btn-secondary" onClick={() => void transactions.refetch()}>Retry</button></p>}
          {transactions.data && <><div className="customer-transactions">{transactions.data.entries.map(transaction => <button className="customer-transaction-row" key={transaction.sale_id} onClick={() => setSaleId(transaction.sale_id)}><span className="customer-transaction-icon"><ReceiptText size={18} /></span><span className="customer-transaction-description"><strong>#{transaction.sale_id.slice(0, 8).toUpperCase()}</strong><time>{customerDay(transaction.created_at)} · {new Date(transaction.created_at).toLocaleTimeString('en-BD', { timeZone: 'Asia/Dhaka', hour: 'numeric', minute: '2-digit' })}</time><span>{formatBDQty(transaction.refill)} refills + {formatBDQty(transaction.package)} packages · {transaction.products || 'No sold products'}</span></span><span className="customer-transaction-amount"><strong>{formatBDT(Number(transaction.total_amount))}</strong><span className="customer-badge retail">Completed</span></span></button>)}</div>
            {!transactions.data.entries.length && <div className="customer-empty"><ReceiptText size={28} /><h3>{transactions.data.total || filters.search || customerActivityFilterCount(filters) ? 'No matching transactions' : 'No transactions yet'}</h3><p>Completed sales will appear here.</p>{transactions.data.total > 0 && <button className="btn btn-secondary" onClick={() => setPage(Math.max(0, Math.ceil(transactions.data.total / CUSTOMER_TRANSACTION_PAGE_SIZE) - 1))}>Go to last page</button>}</div>}
            <Pagination page={page} pageSize={CUSTOMER_TRANSACTION_PAGE_SIZE} total={transactions.data.total} onChange={setPage} label="transactions" busy={transactions.isFetching} />
          </>}
        </> : <p className="customer-notice">You do not have permission to view detailed sales transactions.</p>}
      </>}
    </div><div className="modal-footer"><small>Profile totals cover all completed sales.</small><button className="btn btn-secondary" onClick={onClose}>Close</button></div>
  </PurchaseDialog>{edit && customer && <CustomerFormModal customer={customer} onClose={() => setEdit(false)} />}{filterOpen && <CustomerFiltersModal history filters={filters} onClose={() => setFilterOpen(false)} onApply={next => { setPage(0); setFilters(next); }} />}{saleId && <TransactionDetailsModal saleId={saleId} returnLabel="Back to customer" onClose={() => setSaleId(null)} />}</>;
}
