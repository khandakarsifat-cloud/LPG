import { useAuth } from '../../contexts/AuthContext';
import { useState } from 'react';
import toast from 'react-hot-toast';
import { Check, Loader2 } from 'lucide-react';
import { useSaveStoveProduct, useSaveStoveType, useStoveProducts, useStoveTypes } from '../../hooks/useAccounting';
import { useProductInventory, useSaveProductPrices } from '../../hooks/useInventory';
import type { StoveProduct } from '../../types/accounting';
import { PurchaseDialog, PurchaseNumber } from '../purchases/PurchaseControls';
import { InventoryCostHistory } from './InventoryAdjustments';
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
            <span className="inv-tile-history-hint">Prices & valuation</span>
          </button>
        ))}
      </div>
      {q.data?.length === 0 && (
        <p className="empty-state">Add a stove product, then record valued opening inventory or receive a purchase.</p>
      )}
      {creating && <StoveProductDialog onClose={onCloseCreate} />}
      {selected && <StoveProductDialog product={selected} onClose={() => setSelected(null)} />}
    </>
  );
}

function StoveProductDialog({ product, onClose }: { product?: StoveProduct; onClose: () => void }) {
  const { can } = useAuth(); const types = useStoveTypes(); const save = useSaveStoveProduct();
  const photo = useProductPhoto(product?.image_url);
  const [name, setName] = useState(product?.product_name ?? '');
  const [type, setType] = useState(product?.product_type_id ?? '');
  const [savedId, setSavedId] = useState(product?.item_id); const id = savedId;
  const [saving, setSaving] = useState(false); const busy = save.isPending || photo.busy || saving;
  async function submit(e: React.FormEvent) {
    e.preventDefault(); setSaving(true);
    try {
      const path = await photo.prepare();
      const result = await save.mutateAsync({ ...(id ? { item_id: id } : {}), name: name.trim(), type_id: type, image_url: path });
      setSavedId(result.item_id); await photo.committed(path); toast.success('Product saved');
    } catch { /* Keep details and photo draft; show the upload or server error. */ }
    finally { setSaving(false); }
  }
  return <PurchaseDialog title={id ? 'Stove product details' : 'Add stove product'} subtitle="Product identity, photo and selling prices" onClose={onClose} busy={busy} className="stove-modal stove-modal--wide">
    <div className="modal-body dialog-form">
      <form id="stove-product-form" onSubmit={submit}>
        {save.hasPending && <p role="alert" className="finance-note">A previous product save needs confirmation. <button type="button" className="btn btn-secondary" disabled={busy} onClick={() => void save.mutateAsync(undefined).then(r => { setSavedId(r.item_id); toast.success('Product save confirmed'); }).catch(() => {})}>Recover product save</button></p>}
        <fieldset className="product-form-grid" disabled={busy || !can('inventory:manage')}>
          <div className="product-identity-fields"><label className="input-group"><span className="input-label">Product name</span><input className="input-field" required maxLength={150} placeholder="e.g. Double glass gas stove" value={name} onChange={e => setName(e.target.value)} autoFocus={!id} /></label>
          <label className="input-group"><span className="input-label">Product type</span><select aria-label="Product type" className="input-field" required value={type} onChange={e => setType(e.target.value)}><option value="">Select type</option>{types.data?.filter(t => t.is_active || t.type_id === type).map(t => <option key={t.type_id} value={t.type_id}>{t.name}</option>)}</select></label>
          <p className="finance-note">Stock is added through a purchase or valued inventory adjustment.</p></div>
          <ProductPhotoField photo={photo} disabled={busy || !can('inventory:manage')} />
        </fieldset>
        {save.error && <p className="payment-error" role="alert">{save.error.message}</p>}{types.error && <p className="payment-error" role="alert">{types.error.message}</p>}
      </form>
      {id && <div className="stove-sections"><StovePrices itemId={id} /><InventoryCostHistory itemId={id} /></div>}
    </div>
    <div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>{id ? 'Close' : 'Cancel'}</button>{can('inventory:manage') && <button type="submit" form="stove-product-form" className="btn btn-primary" disabled={busy || save.hasPending || !name.trim() || !type}>{busy ? <><Loader2 size={15} className="spin" />Saving…</> : <><Check size={16} />Save product</>}</button>}</div>
  </PurchaseDialog>;
}

function StovePrices({ itemId }: { itemId: string }) {
  const q = useProductInventory(itemId);
  const save = useSaveProductPrices();
  const [tier, setTier] = useState<'retail' | 'wholesale'>('retail');
  const [value, setValue] = useState<number | null>(null);

  const price = q.data?.prices.find(p => p.customer_tier === tier && p.price_type === 'package');
  const refill = q.data?.prices.find(p => p.customer_tier === tier && p.price_type === 'refill');

  return (
    <section className="product-section">
      <h3>Selling prices</h3>
      <div className="finance-actions">
        {(['retail', 'wholesale'] as const).map(t => (
          <button
            className={`btn ${tier === t ? 'btn-primary' : 'btn-secondary'}`}
            key={t}
            type="button"
            onClick={() => { setTier(t); setValue(null); }}
          >
            {t === 'retail' ? 'Retail' : 'Wholesale'}
          </button>
        ))}
      </div>
      <p style={{ margin: '0.75rem 0' }}>
        {price ? (
          <>Current selling price: Tk {price.price}</>
        ) : (
          <span style={{ color: 'var(--text-muted)' }}>{tier} selling price not set</span>
        )}
      </p>
      {q.data?.can_manage_prices && (
        <form
          onSubmit={async e => {
            e.preventDefault();
            if (value === null) return;
            try {
              await save.mutateAsync({
                itemId,
                tier,
                prices: { refill: { price: 0, mrp: null }, package: { price: value, mrp: null } },
                expected: { refill: refill?.effective_from ?? null, package: price?.effective_from ?? null },
              });
              setValue(null);
              toast.success('Selling price saved');
            } catch {
              /* inline */
            }
          }}
        >
          <PurchaseNumber label="Selling price (Tk)" money value={value} onChange={setValue} />
          <button
            type="submit"
            className="btn btn-primary"
            style={{ marginTop: '0.5rem' }}
            disabled={save.isPending || value === null}
          >
            {save.isPending ? 'Saving…' : 'Save selling price'}
          </button>
        </form>
      )}
      {(save.error || q.error) && (
        <p className="payment-error" role="alert">{save.error?.message ?? q.error?.message}</p>
      )}
    </section>
  );
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
