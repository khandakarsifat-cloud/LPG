import { useState } from 'react';
import { Package, Truck, Calendar, Search } from 'lucide-react';
import { usePurchases } from '../../hooks/usePurchases';
import { PurchaseSelect, PurchaseStatuses } from './PurchaseControls';
import { UpdatePurchaseModal } from './UpdatePurchaseModal';
import { formatBDT } from '../../lib/formatBDT';
import { PURCHASE_STATUS_LABELS, type Purchase } from '../../types/purchase';
import './purchases.css';

export function PurchasesList() {
  const query = usePurchases();
  const purchases = query.data ?? [];
  const [selected, setSelected] = useState<Purchase | null>(null);
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState('all');
  const [payment, setPayment] = useState('all');
  const filtered = purchases.filter(purchase => (status === 'all' || purchase.status === status)
    && (payment === 'all' || purchase.payment_status === payment)
    && `${purchase.company_name ?? ''} ${purchase.plant_name} ${purchase.truck_name ?? ''} ${purchase.notes ?? ''}`.toLowerCase().includes(search.toLowerCase()));
  const unpaid = purchases.filter(purchase => purchase.payment_status === 'unpaid' && purchase.status !== 'created' && purchase.status !== 'cancelled');
  if (query.isLoading) return <div className="purchase-empty">Loading purchases…</div>;
  if (query.isError) return <p role="alert" className="purchase-error">Purchases could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>;
  return <div className="purchases-list">
    <div className="purchase-list-summary"><span>{purchases.filter(p => p.status === 'created').length} created</span>
      <span>{purchases.filter(p => p.status === 'in_transit').length} in transit</span>
      <span>{unpaid.length} awaiting payment · {formatBDT(unpaid.reduce((sum,p) => sum + Number(p.company_payable),0))} company payable</span>
    </div>
    <div className="purchase-toolbar">
      <div className="input-group"><label className="input-label" htmlFor="purchase-search">Search purchases</label><div className="topbar-search">
        <Search size={16} className="topbar-search-icon" /><input id="purchase-search" className="input-field topbar-search-input" placeholder="Company, plant or truck…" value={search} onChange={event => setSearch(event.target.value)} />
      </div></div>
      <PurchaseSelect label="Purchase status" value={status} onChange={setStatus} options={[{ value: 'all', label: 'All statuses' }, ...Object.entries(PURCHASE_STATUS_LABELS).map(([value,label]) => ({ value,label }))]} />
      <PurchaseSelect label="Payment status" value={payment} onChange={setPayment} options={[{ value: 'all', label: 'All payments' }, { value: 'unpaid', label: 'Unpaid' }, { value: 'paid', label: 'Paid' }]} />
    </div>
    {!filtered.length && <div className="purchase-empty"><Package size={24} /><p>{purchases.length ? 'No purchases match these filters.' : 'Create a purchase with a destination plant to get started.'}</p></div>}
    <div className="purchases-grid">{filtered.map(purchase => <button key={purchase.purchase_id} className="glass-panel purchase-card purchase-card-button" onClick={() => setSelected(purchase)}>
      <div className="purchase-card-header"><div><strong>{purchase.plant_name}</strong><p className="purchase-hint">{purchase.company_name ?? 'Historical purchase'}</p></div><PurchaseStatuses purchase={purchase} /></div>
      <div className="purchase-card-body"><div className="purchase-info-row"><Calendar size={14} /><span>{new Date(purchase.created_at).toLocaleDateString('en-BD', { day: 'numeric', month: 'short', year: 'numeric' })}</span></div>
        <div className="purchase-info-row"><Truck size={14} /><span>{purchase.truck_name ?? 'Truck not assigned'}</span></div></div>
      <div className="purchase-items-preview"><div className="purchase-items-count">{purchase.items.length} product lines</div>
        <div className="purchase-items-list">{purchase.items.slice(0, 3).map(item => <div key={item.purchase_item_id} className="purchase-item-pill">
          <span className="pill-qty">{purchase.status === 'received' ? item.received_quantity : item.quantity}×</span><span className="pill-name">{item.size_kg} kg {item.type === 'refill' ? 'refills' : 'new cylinders'}</span>
        </div>)}</div></div>
      <div className="purchase-card-footer"><div><span className="purchase-total-label">Company payable</span><div>{formatBDT(Number(purchase.company_payable))}</div></div>
        <div><span className="purchase-total-label">Total purchase cost</span><div className="purchase-total-value">{formatBDT(Number(purchase.total_cost))}</div></div></div>
    </button>)}</div>
    <UpdatePurchaseModal open={selected !== null} purchase={selected} onClose={() => setSelected(null)} />
  </div>;
}
