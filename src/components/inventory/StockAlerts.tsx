import { lazy, Suspense, useDeferredValue, useState } from 'react';
import toast from 'react-hot-toast';
import { useAuth } from '../../contexts/AuthContext';
import { useSetStockThreshold, useStockAlerts, type StockAlert } from '../../hooks/useStockAlerts';
import { Pagination } from '../ui/Pagination';
import './stock-alerts.css';

const ProductDetails = lazy(() => import('../finance/AccountingBreakdown').then(module => ({ default: module.RelatedRecord })));
function Threshold({ item }: { item: StockAlert }) {
  const [value, setValue] = useState(String(item.low_stock_threshold)); const save = useSetStockThreshold();
  return <form className="stock-threshold-form" onSubmit={async event => { event.preventDefault(); try { await save.mutateAsync({ item, threshold: Number(value) }); toast.success('Stock threshold saved'); } catch { /* inline feedback */ } }}>
    <input type="number" className="input-field" aria-label={`Low stock threshold for ${item.name}`} min={0} max={1000000} step={1} required disabled={save.isPending} value={value} onChange={event => setValue(event.target.value)} />
    <button type="submit" className="btn btn-secondary" disabled={save.isPending || Number(value) === item.low_stock_threshold}>{save.isPending ? 'Saving…' : 'Save'}</button>{save.error && <small role="alert">{save.error.message}</small>}
  </form>;
}
export function StockAlerts({ initiallyLow = false }: { initiallyLow?: boolean }) {
  const { can, profile } = useAuth(); const [low, setLow] = useState(initiallyLow); const [search, setSearch] = useState(''); const [page, setPage] = useState(0); const deferred = useDeferredValue(search);
  const query = useStockAlerts(low, deferred, page); const [selected, setSelected] = useState<StockAlert | null>(null);
  return <section className="stock-alerts"><div className="stock-alerts-toolbar"><h2>Stock alerts</h2><input className="input-field" aria-label="Search stock alerts" placeholder="Search products…" maxLength={200} value={search} onChange={event => { setSearch(event.target.value); setPage(0); }} /><label><input type="checkbox" checked={low} onChange={event => { setLow(event.target.checked); setPage(0); }} />Below threshold only</label></div>
    <p>Alerts count sellable filled LPG bottles and stove units below each product's threshold, including zero stock. A threshold of 0 disables its alert.</p>
    {query.isPending && <p role="status">Loading products…</p>}{query.error && <p role="alert">Stock alerts could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
    <div className="stock-alert-list" aria-busy={query.isFetching}>{query.data?.entries.map(item => <article className="stock-alert-row" key={item.item_id}><button className="stock-alert-product" onClick={() => setSelected(item)}><strong>{item.name}</strong><small>{item.business_category === 'lpg' ? 'LPG' : 'Stove Business'} · {item.filled_quantity} in stock</small></button><div><span className="input-label">Alert below</span>{can('inventory:alerts') ? <Threshold key={`${item.item_id}:${item.low_stock_threshold}`} item={item} /> : <strong>{item.low_stock_threshold}</strong>}</div></article>)}</div>
    {query.data?.entries.length === 0 && <p>No products match these filters.</p>}<Pagination page={page} pageSize={20} total={query.data?.total ?? 0} onChange={setPage} busy={query.isFetching} label="products" />
    {selected && <Suspense fallback={<p role="status">Loading product…</p>}><ProductDetails record={{ tenant_id: profile?.tenant_id ?? '', type_id: '', type_name: '', business_category: selected.business_category, account: '', name: selected.name, entity_id: null, entity_name: selected.name, amount: 0, record_kind: 'product', record_id: selected.item_id }} onClose={() => setSelected(null)} /></Suspense>}
  </section>;
}
