import { useLayoutEffect, useRef, useState, type FormEvent } from 'react';
import { X, Droplets, Box, RefreshCw, RotateCcw, Pencil, Loader2, Package, CalendarDays, Info } from 'lucide-react';
import { format } from 'date-fns';
import toast from 'react-hot-toast';
import { useProductInventory, useSaveProductPrices, useSetProductCommission } from '../../hooks/useInventory';
import { formatBDNumber } from '../../lib/formatBDT';
import type { CustomerTier, ItemWithBrand, PriceType, ProductPrice } from '../../types/inventory';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import '../purchases/purchases.css';
import './inventory.css';

const kinds: PriceType[] = ['refill', 'package'];
const kindLabel = { refill: 'Refill', package: 'Package' };
const money = (value: number) => `Tk ${formatBDNumber(Number(value))}`;
const dateLabel = (value: string, pattern = 'dd MMM yyyy') => format(new Date(`${value.slice(0, 10)}T12:00:00`), pattern);
const weekRange = (start: string, end: string) => {
  if (start.slice(0, 4) !== end.slice(0, 4)) return `${dateLabel(start, 'dd MMM yy')} – ${dateLabel(end, 'dd MMM yy')}`;
  if (start.slice(0, 7) !== end.slice(0, 7)) return `${dateLabel(start, 'dd MMM')} – ${dateLabel(end, 'dd MMM')}`;
  return `${dateLabel(start, 'dd')}–${dateLabel(end, 'dd MMM')}`;
};
const historyFields = [
  { key: 'sold_refill', label: 'Sold refill', shortLabel: 'Refill', icon: RefreshCw, direction: 'out' },
  { key: 'sold_package', label: 'Sold package', shortLabel: 'Package', icon: Box, direction: 'out' },
  { key: 'empty_return', label: 'Empty return', shortLabel: 'Empty', icon: RotateCcw, direction: 'in' },
  { key: 'bought_package', label: 'Bought package', shortLabel: 'Package', icon: Box, direction: 'in' },
  { key: 'bought_refill', label: 'Bought refill', shortLabel: 'Refill', icon: RefreshCw, direction: 'in' },
] as const;

function PricingEditor({ itemId, tier, prices, disabled, onCancel, onSaved, onPending }: {
  itemId: string; tier: CustomerTier; prices: ProductPrice[];
  disabled: boolean;
  onCancel: () => void; onSaved: () => void; onPending: (pending: boolean) => void;
}) {
  const save = useSaveProductPrices();
  const [baseline] = useState(() => ({
    refill: prices.find(p => p.customer_tier === tier && p.price_type === 'refill')?.effective_from ?? null,
    package: prices.find(p => p.customer_tier === tier && p.price_type === 'package')?.effective_from ?? null,
  }));
  const [fields, setFields] = useState(() => {
    const values = (kind: PriceType) => {
      const current = prices.find(p => p.customer_tier === tier && p.price_type === kind)
        ?? prices.find(p => p.customer_tier === 'retail' && p.price_type === kind);
      return { price: current ? String(current.price) : '', mrp: current?.mrp == null ? '' : String(current.mrp) };
    };
    return { refill: values('refill'), package: values('package') };
  });

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (save.isPending || disabled) return;
    onPending(true);
    try {
      await save.mutateAsync({ itemId, tier, expected: baseline, prices: {
        refill: { price: Number(fields.refill.price), mrp: fields.refill.mrp === '' ? null : Number(fields.refill.mrp) },
        package: { price: Number(fields.package.price), mrp: fields.package.mrp === '' ? null : Number(fields.package.mrp) },
      } });
      toast.success('Prices saved');
      onSaved();
    } catch { /* Keep all entered prices; show the server error below. */ }
    finally { onPending(false); }
  };

  return <form onSubmit={submit} className="product-price-form">
    <div className="product-price-table product-price-editor">
      <span /> <span>MRP</span> <span>Selling price</span>
      {kinds.map(kind => <div className="product-price-row" key={kind}>
        <strong>{kindLabel[kind]}</strong>
        {(['mrp', 'price'] as const).map(field => <input key={field} className="input-field" type="number" min="0" max="9999999999.99" step="0.01"
          required={field === 'price'} disabled={save.isPending || disabled} aria-label={`${kindLabel[kind]} ${field === 'mrp' ? 'MRP' : 'selling price'}`}
          placeholder={field === 'mrp' ? 'Optional' : 'Required'} value={fields[kind][field]}
          onChange={event => setFields(previous => ({ ...previous, [kind]: { ...previous[kind], [field]: event.target.value } }))} />)}
      </div>)}
    </div>
    {save.isError && <p role="alert" className="product-error">{save.error.message}</p>}
    <div className="product-price-actions">
      <button type="button" className="btn btn-ghost" onClick={onCancel} disabled={save.isPending || disabled}>Cancel</button>
      <button className="btn btn-primary" disabled={save.isPending || disabled}>{save.isPending && <Loader2 size={14} className="spin" />}Save prices</button>
    </div>
  </form>;
}

function CommissionEditor({ itemId, refillRate, packageRate, version, disabled, onCancel, onSaved, onPending }: {
  itemId: string; refillRate: number; packageRate: number; version: string | null;
  disabled: boolean;
  onCancel: () => void; onSaved: () => void; onPending: (pending: boolean) => void;
}) {
  const save = useSetProductCommission();
  const [values, setValues] = useState({ refill: String(refillRate), package: String(packageRate) });
  const [expected] = useState(version);
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (save.isPending || disabled) return;
    onPending(true);
    try {
      await save.mutateAsync({ itemId, refillRate: Number(values.refill), packageRate: Number(values.package), expected });
      toast.success('Commission saved');
      onSaved();
    } catch { /* Preserve the entered rate and show the server error. */ }
    finally { onPending(false); }
  };
  return <form className="product-commission-form" onSubmit={submit}>
    <div className="product-buying-grid">{kinds.map(kind => <label key={kind}>{kindLabel[kind]} commission / unit
      <input className="input-field" type="number" min="0" max="9999999999.99" step="0.01" required
        disabled={save.isPending || disabled} value={values[kind]}
        onChange={event => setValues(previous => ({ ...previous, [kind]: event.target.value }))} /></label>)}</div>
    {save.isError && <p role="alert" className="product-error">{save.error.message}</p>}
    <div className="product-price-actions"><button type="button" className="btn btn-ghost" disabled={save.isPending || disabled} onClick={onCancel}>Cancel</button>
      <button className="btn btn-primary" disabled={save.isPending || disabled}>{save.isPending && <Loader2 size={14} className="spin" />}Save commission</button></div>
  </form>;
}

export const ProductHistoryModal = ({ item, onClose }: { item: ItemWithBrand; onClose: () => void }) => {
  const dialog = useRef<HTMLDialogElement>(null);
  const product = useProductInventory(item.item_id);
  const [tier, setTier] = useState<CustomerTier>('retail');
  const [editing, setEditing] = useState(false);
  const [editingCommission, setEditingCommission] = useState(false);
  const [commissionEditorVersion, setCommissionEditorVersion] = useState(0);
  const [saving, setSaving] = useState(false);
  const [editorVersion, setEditorVersion] = useState(0);
  const [reloading, setReloading] = useState(false);
  const brandName = item.lpg_brands?.brand_name ?? item.brand;

  useLayoutEffect(() => {
    const panel = dialog.current;
    panel?.showModal();
    return () => panel?.close();
  }, []);

  const reloadPrices = async () => {
    setReloading(true);
    const result = await product.refetch();
    if (result.isSuccess) setEditorVersion(version => version + 1);
    setReloading(false);
  };

  const reloadCommission = async () => {
    setReloading(true);
    const result = await product.refetch();
    if (result.isSuccess) setCommissionEditorVersion(version => version + 1);
    setReloading(false);
  };

  return <><dialog ref={dialog} className="product-dialog" aria-labelledby="product-title"
    onCancel={event => { event.preventDefault(); if (!saving) onClose(); }}
    onClick={event => {
      if (event.target !== event.currentTarget || saving) return;
      const bounds = event.currentTarget.getBoundingClientRect();
      if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) onClose();
    }}>
    <div className="product-dialog-layout">
      <header className="product-dialog-header">
        <div className="product-heading">
          <span className="phm-product-icon"><Package size={21} /></span>
          <div><h2 id="product-title">{brandName} <span>{item.size_kg} kg</span></h2>
            <p>{item.mouth_size ? `${item.mouth_size} mouth` : 'Product details'}</p></div>
        </div>
        <button className="phm-close" aria-label="Close product details" onClick={onClose} disabled={saving}><X size={18} /></button>
      </header>

      <div className="product-dialog-body">
        <section className="product-stock" aria-label="Current stock">
          <div><h3>Current stock</h3><p>Units on hand</p></div>
          <div className="product-stock-value inv-overview-filled"><Droplets size={19} /><div><strong>{item.filled_quantity.toLocaleString()}</strong><span>Filled</span></div></div>
          <div className="product-stock-value inv-overview-empty"><Box size={19} /><div><strong>{item.empty_quantity.toLocaleString()}</strong><span>Empty</span></div></div>
        </section>

        {product.isPending && <div className="product-loading" role="status"><Loader2 size={22} className="spin" />Loading product details…</div>}
        {product.isError && <div className="product-error" role="alert">Could not refresh product details. <button className="btn btn-ghost" onClick={() => product.refetch()}>Retry</button></div>}
        {product.data && <>
          <section className="product-section" aria-labelledby="product-pricing-title">
            <div className="product-section-heading">
              <h3 id="product-pricing-title">Current pricing</h3>
              <div className="product-tier-switch" aria-label="Customer pricing tier">
                {(['retail', 'wholesale'] as const).map(value => <button key={value} aria-pressed={tier === value} disabled={editing}
                  onClick={() => setTier(value)}>{value === 'retail' ? 'Retail' : 'Wholesale'}</button>)}
              </div>
            </div>
            {editing && product.data.can_manage_prices ? <PricingEditor key={`${tier}-${editorVersion}`} itemId={item.item_id} tier={tier} prices={product.data.prices} disabled={reloading}
              onCancel={() => setEditing(false)} onSaved={() => setEditing(false)} onPending={setSaving} />
              : <div className="product-price-table">
                <span /> <span>MRP</span> <span>Selling price</span>
                {kinds.map(kind => {
                  const own = product.data.prices.find(p => p.customer_tier === tier && p.price_type === kind);
                  const price = own ?? product.data.prices.find(p => p.customer_tier === 'retail' && p.price_type === kind);
                  return <div className="product-price-row" key={kind}>
                    <strong>{kind === 'refill' ? <RefreshCw size={14} /> : <Box size={14} />}{kindLabel[kind]}</strong>
                    <span className="product-mrp">{price?.mrp == null ? '—' : money(price.mrp)}</span>
                    <div><strong>{price ? money(price.price) : 'Not set'}</strong>{!own && price && tier === 'wholesale' && <small>Retail price applies</small>}</div>
                  </div>;
                })}
              </div>}
            <div className="product-price-note">
              <p>MRP is for reference. Sales use the selling price; discounts apply separately.</p>
              {product.data.can_manage_prices && (editing
                ? <button className="btn btn-ghost" disabled={saving || reloading} onClick={reloadPrices}>Reload saved prices</button>
                : <button className="btn btn-secondary" disabled={editingCommission} onClick={() => setEditing(true)}><Pencil size={13} />Edit prices</button>)}
            </div>
          </section>

          <section className="product-section" aria-labelledby="product-buying-title">
            <div className="product-section-heading"><h3 id="product-buying-title">Estimated buying price</h3><span className="product-approx">Per unit · approximate</span></div>
            <div className="product-buying-grid">
              {kinds.map(kind => {
                const cost = product.data.buying_costs.find(entry => entry.type === kind);
                return <div className="product-buying" key={kind}>
                  <div className="product-buying-heading"><span>{kindLabel[kind]}</span><strong>{cost ? money(cost.estimated_unit_cost) : '—'}</strong></div>
                  {cost ? <>
                    <p>{cost.received_at ? `Received ${format(new Date(cost.received_at), 'dd MMM yyyy')}` : 'Last received purchase'}</p>
                    <dl><div><dt>Bottle cost</dt><dd>{money(cost.bottle_cost)}</dd></div>
                      <div><dt>Transport + labour / unit</dt><dd>+ {money(cost.overhead_per_unit)}</dd></div>
                      <div><dt>Commission / unit</dt><dd className="product-commission-rate">− {money(cost.commission_per_unit)}</dd></div>
                    </dl>
                  </> : <><p>No received {kindLabel[kind].toLowerCase()} purchase yet.</p>
                    <dl><div><dt>Commission / unit</dt><dd className="product-commission-rate">{product.data.commission.version ? money(kind === 'refill' ? product.data.commission.refill_rate : product.data.commission.package_rate) : 'Not set'}</dd></div></dl></>}
                </div>;
              })}
            </div>
            {product.data.can_manage_prices && <div className="product-buying-actions"><button className="btn btn-secondary" disabled={editing}
              onClick={() => setEditingCommission(true)}><Pencil size={13} />Edit commission</button></div>}
            <p className="product-help">Latest received purchase for this exact product and type, plus shared transport and labour, minus its current manually set commission. Purchase commission is ignored.</p>
          </section>

          <section className="product-section product-history" aria-labelledby="product-history-title">
            <div className="product-section-heading product-history-heading">
              <div><h3 id="product-history-title"><CalendarDays size={16} />Weekly history</h3><p>Sat–Fri · Bangladesh time</p></div>
              <details className="product-history-info">
                <summary aria-label="About weekly history"><Info size={16} aria-hidden="true" /></summary>
                <p>Quantities in units. Sales leave stock (−); empty returns and received purchases add stock (+). Only completed sales and received purchases are included. Cancelled purchases are excluded.</p>
              </details>
            </div>
            <div className="product-history-head" aria-hidden="true">
              <span className="product-history-week-label">Week</span>
              <div className="product-history-columns">
                <div className="product-history-groups"><span>Sold</span><span>Stock in</span></div>
                <div className="product-history-labels">
                  {historyFields.map(({ key, shortLabel, icon: Icon }) => <span key={key}><Icon size={13} />{shortLabel}</span>)}
                </div>
              </div>
            </div>
            <div className="product-weeks">
              {product.data.weeks.map((week, index) => <article className="product-week" key={week.start_date}>
                <div className="product-week-heading"><h4>{index === 0 ? 'This week' : index === 1 ? 'Last week' : `${index} weeks ago`}</h4>
                  <time dateTime={week.start_date} title={`${dateLabel(week.start_date)} – ${dateLabel(week.end_date)}`}>{weekRange(week.start_date, week.end_date)}</time></div>
                <dl className="product-week-metrics">
                  {historyFields.map(({ key, label, direction }) => {
                    const quantity = week[key];
                    const signed = quantity === 0 ? '0' : `${direction === 'out' ? '-' : '+'}${quantity.toLocaleString()}`;
                    return <div key={key} title={`${label}: ${signed}`}><dt className="product-history-sr-only">{label}</dt>
                      <dd className={`product-history-${quantity === 0 ? 'zero' : direction}`}>{signed}</dd></div>;
                  })}
                </dl>
              </article>)}
            </div>
          </section>
        </>}
      </div>
    </div>
  </dialog>
    {editingCommission && product.data?.can_manage_prices && <PurchaseDialog title="Edit commission" subtitle={`${brandName} ${item.size_kg} kg · Commission per unit`}
      compact busy={saving || reloading} onClose={() => setEditingCommission(false)}>
      <div className="modal-body product-commission-popup">
        <p className="product-help">Set refill and package rates separately. Each rate reduces its estimated buying price.</p>
        <CommissionEditor key={commissionEditorVersion} itemId={item.item_id} refillRate={product.data.commission.refill_rate}
          packageRate={product.data.commission.package_rate} version={product.data.commission.version} disabled={reloading}
          onCancel={() => setEditingCommission(false)} onSaved={() => setEditingCommission(false)} onPending={setSaving} />
        <button className="btn btn-ghost" disabled={saving || reloading} onClick={reloadCommission}>Reload saved rates</button>
      </div>
    </PurchaseDialog>}
  </>;
};
