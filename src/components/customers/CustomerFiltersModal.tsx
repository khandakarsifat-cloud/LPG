import { useState, type FormEvent } from 'react';
import { ChevronRight, Package, RotateCcw } from 'lucide-react';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { DatePicker } from '../ui/DatePicker';
import { InventoryProductPicker } from '../inventory/InventoryProductPicker';
import { useCustomerProductOptions } from '../../hooks/useCustomerDirectory';
import { customerPeriod, defaultCustomerFilters } from '../../lib/customer';
import type { CustomerFilters } from '../../types/customer';

export function CustomerFiltersModal({ filters, onApply, onClose, history = false }: {
  filters: CustomerFilters; onApply: (filters: CustomerFilters) => void; onClose: () => void; history?: boolean;
}) {
  const [draft, setDraft] = useState(filters); const [picker, setPicker] = useState(false);
  const [error, setError] = useState('');
  const options = useCustomerProductOptions();
  const field = (key: keyof CustomerFilters, value: string) => setDraft(previous => ({ ...previous, [key]: value }));
  const apply = (event: FormEvent) => {
    event.preventDefault();
    for (const key of ['transactions', 'refill', 'package'] as const) {
      const lo = draft[`${key}_min`], hi = draft[`${key}_max`];
      if (lo && hi && Number(lo) > Number(hi)) { setError('A minimum cannot exceed its maximum.'); return; }
    }
    if (draft.from && draft.to && draft.from > draft.to) { setError('Start date must not follow end date.'); return; }
    onApply(draft); onClose();
  };
  const selected = draft.item_ids === null ? 'All products' : `${draft.item_ids.length} products selected`;
  return <><PurchaseDialog title={history ? 'Filter transactions' : 'Advanced filters'} subtitle="Find customer activity by what was bought and when." onClose={onClose}>
    <form onSubmit={apply} className="customer-filters-form"><div className="modal-body">
      {error && <p role="alert" className="purchase-error">{error}</p>}
      <section className="customer-filter-section"><h3>Activity period <small>Bangladesh time</small></h3><div className="customer-periods">
        {[['all', 'All time'], ['week', 'This week'], ['month', 'This month']].map(([value, label]) => <button key={value} type="button" className="btn btn-secondary" onClick={() => setDraft(previous => ({ ...previous, ...customerPeriod(value) }))}>{label}</button>)}
      </div><div className="customer-date-fields"><div className="input-group"><label className="input-label" htmlFor="customer-from">From</label><DatePicker id="customer-from" label="From" value={draft.from} max={draft.to || undefined} onChange={value => field('from', value)} /></div><div className="input-group"><label className="input-label" htmlFor="customer-to">To</label><DatePicker id="customer-to" label="To" value={draft.to} min={draft.from || undefined} onChange={value => field('to', value)} /></div></div><p className="customer-help">Both dates are included. Sales, dues, quantities and Last Sale use this period. Dues reflect payments received through today.</p></section>
      <section className="customer-filter-section"><h3>Products to consider</h3><button type="button" className="customer-product-select" disabled={!options.data} onClick={() => setPicker(true)}><Package size={18} /><span><strong>{selected}</strong><small>Refill and package quantities for these products only</small></span><ChevronRight size={17} /></button>
        {options.isError && <p role="alert" className="purchase-error">Products could not be loaded. <button className="btn btn-ghost" type="button" onClick={() => void options.refetch()}>Retry</button></p>}
        {options.isPending && <p className="customer-help">Loading product selection…</p>}
        <div className="customer-filter-chips">{draft.item_ids?.slice(0, 3).map(id => { const product = options.data?.items.find(item => item.item_id === id); return product ? <span key={id}>{product.lpg_brands?.brand_name ?? product.brand} {product.size_kg} kg {product.mouth_size}</span> : null; })}{draft.item_ids && draft.item_ids.length > 3 && <span>+{draft.item_ids.length - 3} more</span>}</div>
      </section>
      {!history && <section className="customer-filter-section"><h3>Customer activity</h3><div className="customer-range-grid"><span /><span>At least</span><span>At most</span>
        {([['transactions', 'Transactions'], ['refill', 'Refills sold'], ['package', 'Packages sold']] as const).map(([key, label]) => <div className="customer-range-row" key={key}><span>{label}</span>{(['min', 'max'] as const).map(bound => <input key={bound} className="input-field" type="number" min="0" step="1" inputMode="numeric" aria-label={`${label} ${bound === 'min' ? 'minimum' : 'maximum'}`} value={draft[`${key}_${bound}`]} placeholder={bound === 'min' ? '0' : 'Any'} onChange={event => field(`${key}_${bound}`, event.target.value)} />)}</div>)}
      </div><p className="customer-help">Each completed sale counts once. A matching refill or package includes the whole sale value and its remaining due. Quantities count selected products only; empty returns are excluded. Activity filters exclude customers with no qualifying sales.</p></section>}
      {!history && <p className="customer-notice">Overview figures stay business-wide. Customer results and sales figures use these filters.</p>}
    </div><div className="modal-footer"><button className="btn btn-secondary" type="button" onClick={() => setDraft({ ...defaultCustomerFilters, search: filters.search, tier: filters.tier, sort: filters.sort })}><RotateCcw size={14} />Reset</button><div className="customer-footer-actions"><button type="button" className="btn btn-secondary" onClick={onClose}>Cancel</button><button type="submit" className="btn btn-primary">Apply filters</button></div></div></form>
  </PurchaseDialog>{picker && options.data && <InventoryProductPicker items={options.data.items} brands={options.data.brands} selected={draft.item_ids} showStock={false} subtitle="Choose products to use in customer activity filters." onClose={() => setPicker(false)} onApply={ids => { setDraft(previous => ({ ...previous, item_ids: ids })); setPicker(false); }} />}</>;
}
