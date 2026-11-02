import './product-details.css';
import { useAuth } from '../../contexts/AuthContext';
import { useState } from 'react';
import toast from 'react-hot-toast';
import { useSaveStoveProduct, useSaveStoveType, useStoveProducts, useStoveTypes } from '../../hooks/useAccounting';
import { useProductInventory, useSaveProductPrices } from '../../hooks/useInventory';
import type { StoveProduct } from '../../types/accounting';
import { PurchaseDialog, PurchaseNumber } from '../purchases/PurchaseControls';
import { StoveStockActivity } from './StoveStockActivity';
import type { ProductInventory } from '../../types/inventory';
import { formatBDT } from '../../lib/formatBDT';
import { useProductPhoto } from '../../hooks/useProductImages';
import { ProductImage, ProductPhotoField } from './ProductImage';

export function StoveInventory({ creating, onCloseCreate }: { creating: boolean; onCloseCreate: () => void }) {
  const q = useStoveProducts();
  const types = useStoveTypes();
  const [selected, setSelected] = useState<StoveProduct | null>(null);

  return (
    <>
      {q.isPending && <p role="status">Loading stove inventory…</p>}
      {q.error && <p role="alert" className="payment-error">{q.error.message}</p>}
      <div className="stove-catalog inv-tiles-grid adaptive-grid adaptive-grid--inventory">
        {q.data?.map(p => (
          <button className="inv-tile stove-tile" key={p.item_id} onClick={() => setSelected(p)}>
            <ProductImage path={p.image_url} name={p.product_name} className="product-image--catalog" />
            <strong className="inv-tile-brand">{p.product_name}</strong>
            <span className="stove-tile-type">{types.data?.find(t => t.type_id === p.product_type_id)?.name}</span>
            <div className="inv-tile-counts">
              <strong className="inv-tile-count inv-tile-count-filled">{p.filled_quantity} in stock</strong>
            </div>
            <span className="inv-tile-history-hint">Product details</span>
          </button>
        ))}
      </div>
      {q.data?.length === 0 && (
        <p className="empty-state">Add a product, then receive stock from a supplier.</p>
      )}
      {creating && <StoveProductDialog onClose={onCloseCreate} />}
      {selected && <StoveProductDialog product={selected} onClose={() => setSelected(null)} />}
    </>
  );
}

export function StoveProductDialog({ product, onClose }: { product?: StoveProduct; onClose: () => void }) {
 const { can } = useAuth(); const types = useStoveTypes(); const save = useSaveStoveProduct(); const photo = useProductPhoto(product?.image_url);
 const [name, setName] = useState(product?.product_name ?? ''); const [type, setType] = useState(product?.product_type_id ?? '');
 const [id, setId] = useState(product?.item_id); const [tab, setTab] = useState<'details' | 'activity'>('details');
 const [saving, setSaving] = useState(false); const busy = save.isPending || photo.busy || saving;
 async function submit(e: React.FormEvent) {
  e.preventDefault(); setSaving(true);
  try { const path = await photo.prepare(); const result = await save.mutateAsync({ ...(id ? { item_id: id } : {}), name: name.trim(), type_id: type, image_url: path }); setId(result.item_id); await photo.committed(path); toast.success('Product saved'); }
  catch { /* Preserve the draft and show its upload/server error. */ } finally { setSaving(false); }
 }
 return <PurchaseDialog title={id ? product?.product_name ?? name : 'Add stove product'} subtitle={id ? `${product?.filled_quantity ?? 0} ${product?.filled_quantity === 1 ? 'unit' : 'units'} in stock` : 'Name, type and optional photo'} onClose={onClose} busy={busy} className="stove-product-dialog">
  {id && <nav className="stove-product-tabs" aria-label="Stove product"><button aria-current={tab === 'details' ? 'page' : undefined} onClick={() => setTab('details')}>Product & prices</button><button aria-current={tab === 'activity' ? 'page' : undefined} onClick={() => setTab('activity')}>Stock activity</button></nav>}
  <div className="modal-body stove-product-body">
   {tab === 'details' ? <div className="stove-product-layout"><form id="stove-product-form" className="stove-product-identity" onSubmit={submit}>
    <h3>Product details</h3>
    {save.hasPending && <p role="alert">A previous save needs confirmation. <button type="button" className="btn btn-secondary" disabled={busy} onClick={() => void save.mutateAsync(undefined).then(r => setId(r.item_id)).catch(() => {})}>Recover product save</button></p>}
    <fieldset disabled={busy || !can('inventory:manage')}><label className="input-group"><span className="input-label">Product name</span><input className="input-field" required maxLength={150} value={name} onChange={e => setName(e.target.value)} autoFocus={!id} /></label>
     <label className="input-group"><span className="input-label">Product type</span><select className="input-field" aria-label="Product type" required value={type} onChange={e => setType(e.target.value)}><option value="">Select type</option>{types.data?.filter(t => t.is_active || t.type_id === type).map(t => <option value={t.type_id} key={t.type_id}>{t.name}</option>)}</select></label>
     <ProductPhotoField photo={photo} disabled={busy || !can('inventory:manage')} />
    </fieldset>{(save.error || types.error) && <p role="alert" className="payment-error">{save.error?.message ?? types.error?.message}</p>}
   </form>{id && <StovePrices itemId={id} />}</div> : id && <StoveStockActivity itemId={id} />}
  </div>
  <div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>{id ? 'Close' : 'Cancel'}</button>{tab === 'details' && can('inventory:manage') && <button type="submit" form="stove-product-form" className="btn btn-primary" disabled={busy || save.hasPending || !name.trim() || !type}>{busy ? 'Saving…' : 'Save product'}</button>}</div>
 </PurchaseDialog>;
}
function StovePrices({ itemId }: { itemId: string }) {
 const q = useProductInventory(itemId);
 return <section className="stove-product-prices"><h3>Selling prices</h3>{q.isPending && <p role="status">Loading prices…</p>}{q.error && <p role="alert" className="payment-error">{q.error.message}</p>}
  {q.data && <div className="stove-price-cards">{(['retail', 'wholesale'] as const).map(tier => <StovePrice key={tier} itemId={itemId} tier={tier} data={q.data} />)}</div>}
 </section>;
}
function StovePrice({ itemId, tier, data }: { itemId: string; tier: 'retail' | 'wholesale'; data: ProductInventory }) {
 const save = useSaveProductPrices(); const [editing, setEditing] = useState(false); const [value, setValue] = useState<number | null>(null);
 const own = data.prices.find(p => p.customer_tier === tier && p.price_type === 'package');
 const fallback = data.prices.find(p => p.customer_tier === 'retail' && p.price_type === 'package'); const price = own ?? fallback;
 const refill = data.prices.find(p => p.customer_tier === tier && p.price_type === 'refill');
 return <article className="stove-price-card"><header><h4>{tier === 'retail' ? 'Retail' : 'Wholesale'}</h4>{data.can_manage_prices && !editing && <button className="btn btn-ghost" onClick={() => { setValue(own?.price ?? price?.price ?? 0); setEditing(true); }}>Edit</button>}</header>
  {editing ? <form onSubmit={async e => { e.preventDefault(); if (value === null) return; try { await save.mutateAsync({ itemId, tier, prices: { refill: { price: 0, mrp: null }, package: { price: value, mrp: null } }, expected: { refill: refill?.effective_from ?? null, package: own?.effective_from ?? null } }); setEditing(false); toast.success('Selling price saved'); } catch { /* inline */ } }}>
   <PurchaseNumber label={`${tier === 'retail' ? 'Retail' : 'Wholesale'} selling price (Tk)`} money value={value} onChange={setValue} /><div className="finance-actions"><button className="btn btn-secondary" type="button" disabled={save.isPending} onClick={() => setEditing(false)}>Cancel</button><button className="btn btn-primary" disabled={save.isPending || value === null}>Save price</button></div>{save.error && <p role="alert" className="payment-error">{save.error.message}</p>}
  </form> : <><strong className="stove-price-amount">{price ? formatBDT(price.price) : 'Not set'}</strong>{!own && price && tier === 'wholesale' && <small>Retail price applies</small>}</>}
 </article>;
}

export function StoveProductTypes() {
  const q = useStoveTypes();
  const save = useSaveStoveType();
  const [name, setName] = useState('');

  return (
    <section className="settings-section">
      <header className="settings-section-heading">
        <div>
          <h2>Stove product types</h2>
          <p>Classify stove products without LPG weights or bottle settlement.</p>
        </div>
      </header>
      <form
        className="glass-panel accounting-card settings-profile-form"
        onSubmit={async e => {
          e.preventDefault();
          try {
            await save.mutateAsync({ name, active: true });
            setName('');
          } catch {
            /* inline */
          }
        }}
      >
        <label className="input-group">
          <span className="input-label">Type name</span>
          <input
            className="input-field"
            required
            maxLength={80}
            value={name}
            onChange={e => setName(e.target.value)}
          />
        </label>
        <button className="btn btn-primary" disabled={save.isPending}>Add type</button>
      </form>
      {(q.error || save.error) && (
        <p className="payment-error" role="alert">{q.error?.message ?? save.error?.message}</p>
      )}
      {q.data?.map(t => (
        <div className="glass-panel accounting-card finance-heading" key={t.type_id}>
          <strong>{t.name}</strong>
          <button
            className="btn btn-secondary"
            disabled={save.isPending}
            onClick={() => save.mutate({ name: t.name, type_id: t.type_id, active: !t.is_active })}
          >
            {t.is_active ? 'Archive' : 'Restore'}
          </button>
        </div>
      ))}
    </section>
  );
}

export function StoveInventorySummary() {
  const q = useStoveProducts();
  const rows = q.data ?? [];
  return (
    <>
      {[
        ['Stock units', rows.reduce((sum, p) => sum + p.filled_quantity, 0)],
        ['Low stock (1–5)', rows.filter(p => p.filled_quantity > 0 && p.filled_quantity <= 5).length],
        ['Out of stock', rows.filter(p => p.filled_quantity === 0).length],
        ['Stove products', rows.length],
      ].map(([label, value]) => (
        <div className="inv-hub-module inv-overview-box" key={label}>
          <span className="inv-hub-label">{label}</span>
          <strong className="inv-hub-num">
            {q.isPending || q.error ? '—' : Number(value).toLocaleString()}
          </strong>
        </div>
      ))}
    </>
  );
}
