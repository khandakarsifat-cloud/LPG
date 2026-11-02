import { useState, type FormEvent } from 'react';
import { History, Pencil } from 'lucide-react';
import toast from 'react-hot-toast';
import { useOperationalPriceHistory, useSetBuyingPrice } from '../../hooks/useInventory';
import type { BuyingPrice, PriceType, ProductInventory } from '../../types/inventory';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';

const date = (value: string) => new Date(value).toLocaleString('en-BD', { timeZone: 'Asia/Dhaka', dateStyle: 'medium', timeStyle: 'short' });
const amount = (value: number | null | undefined) => value == null ? 'Not available' : formatBDT(value);

export function OperationalPrices({ itemId, data, disabled }: { itemId: string; data: ProductInventory; disabled: boolean }) {
  const [editing, setEditing] = useState<PriceType | null>(null);
  return <div className="operational-buying" aria-labelledby="operational-buying-title">
    <div className="product-section-heading"><h4 id="operational-buying-title">Approximate buying prices</h4><span className="product-approx">Operational reference · per unit</span></div>
    <div className="product-buying-grid">{(['refill', 'package'] as const).map(kind => {
      const price = data.buying_prices.find(p => p.price_type === kind);
      return <article className="product-buying" key={kind}><div className="product-buying-heading"><span>{kind === 'refill' ? 'Refill' : 'Package'}</span><strong>{amount(price?.new_price)}</strong></div>
        <p>{price?.is_manual ? 'Manual override' : 'Latest received purchase suggestion'}</p>
        <dl><div><dt>Purchase / unit</dt><dd>{amount(price?.bottle_cost)}</dd></div><div><dt>Transport + labour / unit</dt><dd>{amount(price?.overhead_per_unit)}</dd></div></dl>
        {price?.is_manual && <small>Automatic suggestion: {amount(price.automatic_price)}</small>}
        {data.can_manage_prices && <button className="btn btn-secondary" disabled={disabled} onClick={() => setEditing(kind)}><Pencil size={13} />Edit approximate price</button>}
      </article>;
    })}</div>
    <p className="product-help">Latest purchase + transport and labour − the commission shown above. Approximate references only.</p>
    <PriceHistory itemId={itemId} />
    {editing && <BuyingEditor itemId={itemId} kind={editing} current={data.buying_prices.find(p => p.price_type === editing)} onClose={() => setEditing(null)} />}
  </div>;
}

function BuyingEditor({ itemId, kind, current, onClose }: { itemId: string; kind: PriceType; current?: BuyingPrice; onClose: () => void }) {
  const save = useSetBuyingPrice(); const [mode, setMode] = useState('manual');
  const [expected, setExpected] = useState(current?.history_id ?? null);
  const [price, setPrice] = useState(current?.new_price == null ? '' : String(current.new_price)); const [reason, setReason] = useState('');
  async function submit(e: FormEvent) {
    e.preventDefault();
    try { await save.mutateAsync({ item_id: itemId, price_type: kind, is_manual: mode === 'manual', ...(mode === 'manual' ? { price: Number(price) } : {}), reason, expected }); toast.success('Approximate buying price saved'); onClose(); } catch { /* Preserve draft and show the server error. */ }
  }
  return <PurchaseDialog title={`Approximate ${kind} buying price`} subtitle="Operational reference only" compact busy={save.isPending} onClose={onClose}>
    <form onSubmit={submit}><div className="modal-body dialog-form">
      <label className="input-group"><span className="input-label">Price source</span><select className="input-field" value={mode} onChange={e => setMode(e.target.value)}><option value="manual">Manual override</option><option value="automatic" disabled={current?.automatic_price == null}>Use automatic suggestion</option></select></label>
      {mode === 'manual' ? <label className="input-group"><span className="input-label">Approximate price (Tk)</span><input className="input-field" required type="number" inputMode="decimal" min="0" max="9999999999.99" step="0.01" value={price} onChange={e => setPrice(e.target.value)} /></label> : <p>Automatic suggestion: <strong>{amount(current?.automatic_price)}</strong></p>}
      <label className="input-group"><span className="input-label">Reason for change</span><textarea className="input-field" required maxLength={1000} value={reason} onChange={e => setReason(e.target.value)} /></label>
      {save.hasPending && <p className="finance-note">A previous save needs confirmation. <button type="button" className="btn btn-secondary" disabled={save.isPending} onClick={() => void save.mutateAsync(undefined).then(onClose).catch(() => {})}>Recover price save</button></p>}
      {save.error && <p role="alert" className="payment-error">{save.error.message}</p>}
      <button type="button" className="btn btn-ghost" disabled={save.isPending || save.hasPending} onClick={() => { setExpected(current?.history_id ?? null); setPrice(current?.new_price == null ? '' : String(current.new_price)); }}>Reload saved price</button>
    </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={save.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={save.isPending || save.hasPending}>{save.isPending ? 'Saving…' : 'Save approximate price'}</button></div></form>
  </PurchaseDialog>;
}

function PriceHistory({ itemId }: { itemId: string }) {
  const [open, setOpen] = useState(false); const [page, setPage] = useState(0); const q = useOperationalPriceHistory(itemId, page, open);
  return <details className="operational-price-history" onToggle={e => setOpen(e.currentTarget.open)}><summary><History size={14} />Buying-price history</summary>
    {q.isPending && open && <p role="status">Loading history…</p>}{q.error && <p role="alert" className="payment-error">{q.error.message}</p>}
    {q.data && <><div className="buying-history-list">{q.data.entries.map(e => <article className="price-history-entry" key={e.history_id}>
      <strong>{`${e.price_type}: ${amount(e.previous_price)} → ${amount(e.new_price)}`}</strong>
      <small>{date(e.effective_at)} · {e.actor}{e.reconstructed ? ' · Reconstructed from records' : ''}</small>
      <p>{e.reason}{e.purchase_id && ` · Purchase #${e.purchase_id.slice(0, 8).toUpperCase()}`}</p>
    </article>)}</div>{!q.data.total && <p>No saved changes yet.</p>}<Pagination page={page} pageSize={10} total={q.data.total} onChange={setPage} busy={q.isFetching} label="buying price changes" /></>}
  </details>;
}
