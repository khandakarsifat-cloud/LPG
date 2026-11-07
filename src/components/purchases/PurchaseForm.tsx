import { useListPage } from '../../hooks/useListPage';
import { Pagination } from '../ui/Pagination';
import { Plus, Trash2, Package } from 'lucide-react';
import { useInventoryBalances } from '../../hooks/useInventory';
import { useVehicles } from '../../hooks/useLogistics';
import { PurchaseNumber, PurchaseSelect, PurchaseFinancials } from './PurchaseControls';
import { purchaseTotals } from '../../lib/purchase';
import { formatBDT } from '../../lib/formatBDT';
import type { Purchase, PurchaseDraft, PurchaseLinePayload } from '../../types/purchase';
import { ProductImage } from '../inventory/ProductImage';

export function PurchaseShipment({ draft, onChange }: { draft: PurchaseDraft; onChange: (draft: PurchaseDraft) => void }) {
  const vehiclesQuery = useVehicles();
  const vehicles = (vehiclesQuery.data ?? []).filter(vehicle => vehicle.status === 'idle' || vehicle.vehicle_id === draft.vehicle_id);
  return <div>
    <PurchaseSelect label="Vehicle (optional until dispatch)" value={draft.vehicle_id ?? ''} onChange={id => onChange({ ...draft, vehicle_id: id || null })}
      placeholder={vehiclesQuery.isLoading ? 'Loading vehicles…' : 'Assign an idle vehicle'}
      options={[{ value: '', label: 'Assign later' }, ...vehicles.map(vehicle => ({ value: vehicle.vehicle_id, label: vehicle.name, description: `${vehicle.serial_no} · ${vehicle.driver_name || "Needs Driver assignment"}` }))]} />
    {vehiclesQuery.isError && <p role="alert" className="purchase-error">Vehicles could not be loaded. <button type="button" className="btn btn-ghost" onClick={() => void vehiclesQuery.refetch()}>Retry</button></p>}
  </div>;
}

export function PurchaseForm({ draft, onChange, companyId, purchase, showShipment = true }: {
  draft: PurchaseDraft; onChange: (draft: PurchaseDraft) => void; companyId: string | null; purchase?: Purchase; showShipment?: boolean;
}) {
  const itemsQuery = useInventoryBalances();
  const paging = useListPage(draft.items, 6, companyId ?? "");
  const items = (itemsQuery.data ?? []).filter(item => item.brand_id === companyId);
  const productsEditable = !purchase || purchase.status === 'created';
  // The detail controller renders this editor only while financial edits are allowed.
  // Partial status may represent dispatch funding before any normal payment.
  const financialsEditable = !purchase || purchase.status !== 'received' && Number(purchase.paid_amount ?? 0) === 0 && purchase.payment_status !== 'paid';
  const totals = purchaseTotals(draft.items, draft.transport_cost, draft.labour_cost);
  function updateLine(index: number, patch: Partial<PurchaseLinePayload>) {
    onChange({ ...draft, items: draft.items.map((line, i) => {
      if (i !== index) return line;
      const updated = { ...line, ...patch };
      return updated;
    }) });
  }
  return <>
    {productsEditable && showShipment && <section className="purchase-section"><h3>Shipment</h3>
      <PurchaseShipment draft={draft} onChange={onChange} />
    </section>}
    <section className="purchase-section">
      <div className="purchase-section-heading"><div><h3>Gas & Bottle purchases</h3>
        <p className="purchase-hint">{productsEditable ? 'Enter each product’s quantities and prices in its own card.' : 'Products and expected quantities are locked after dispatch.'}</p></div>
        {productsEditable && <button type="button" className="btn btn-secondary" disabled={!companyId} onClick={() => { paging.setPage(Math.floor(draft.items.length / paging.pageSize)); onChange({ ...draft,
          items: [...draft.items, { item_id: '', quantity: 1, bottle_quantity: 0, unit_price: 0, bottle_unit_price: 0 }],
        }); }}><Plus size={15} /> Add product</button>}
      </div>
      {itemsQuery.isError && productsEditable && <p role="alert" className="purchase-error">Products could not be loaded. <button type="button" className="btn btn-ghost" onClick={() => void itemsQuery.refetch()}>Retry</button></p>}
      {!draft.items.length && <div className="purchase-empty"><Package size={22} /><p>Products can be added later.</p></div>}
      <div className="purchase-lines">{paging.entries.map((line, localIndex) => {
        const index = paging.page * paging.pageSize + localIndex;
        const item = items.find(item => item.item_id === line.item_id);
        const saved = purchase?.items.find(item => item.purchase_item_id === line.purchase_item_id);
        return <article className="purchase-product-card" aria-label={`Product ${index + 1} details`} key={line.purchase_item_id ?? index}>
          <header className="purchase-product-header"><span className="purchase-product-index">Product {index + 1}</span>
            {productsEditable && <button type="button" className="btn btn-ghost purchase-remove" aria-label={`Remove product ${index + 1}`} onClick={() => onChange({ ...draft, items: draft.items.filter((_, i) => i !== index) })}><Trash2 size={16} /> Remove</button>}
          </header>
            {productsEditable ? <div className="purchase-line-product"><PurchaseSelect label={`Product ${index + 1}`} value={line.item_id} onChange={id => updateLine(index, { item_id: id })}
              options={items.filter(item => !draft.items.some((other, i) => i !== index && other.item_id === item.item_id))
                .map(item => ({ value: item.item_id, label: `${item.lpg_brands?.brand_name ?? 'Product unavailable'} ${item.size_kg} kg${item.mouth_size ? ` · ${item.mouth_size}` : ''}`,
                  }))} />
              {item && <p className="purchase-stock-caption">Filled = {item.filled_quantity} <span>·</span> Empty = {item.empty_quantity}</p>}
              {item?.image_url && <ProductImage path={item.image_url} name={item.lpg_brands?.brand_name ?? 'Selected product'} />}</div>
              : <div className="product-with-image">{saved?.image_url && <ProductImage path={saved.image_url} name={saved.brand_name} />}<strong>{saved?.brand_name} {saved?.size_kg} kg {saved?.mouth_size}</strong></div>}
            <div className="purchase-component-fields"><div className="purchase-component purchase-component-gas"><h4>Gas</h4>
            {productsEditable ? <>
              <PurchaseNumber label="Gas quantity" value={line.quantity} onChange={n => updateLine(index, { quantity: n ?? 0 })} />
            </> : <dl className="purchase-line-quantities">
              <div><dt>Gas</dt><dd>{line.quantity}</dd></div><div><dt>Additional Bottles</dt><dd>{line.bottle_quantity}</dd></div>
              <div><dt>Empties sent</dt><dd>{saved?.bottles_dispatched}</dd></div><div><dt>Filled received</dt><dd>{purchase?.status === 'received' ? line.quantity : 'Pending'}</dd></div>
            </dl>}
            {financialsEditable ? <>
              <PurchaseNumber label="Gas unit price (Tk)" value={line.unit_price} money onChange={n => updateLine(index, { unit_price: n ?? 0 })} />
            </> : <dl><div><dt>Gas unit price</dt><dd>{formatBDT(line.unit_price)}</dd></div><div><dt>Bottle unit price</dt><dd>{formatBDT(line.bottle_unit_price)}</dd></div></dl>}
            </div><div className="purchase-component purchase-component-bottle"><h4>Additional bottles</h4>
              {productsEditable && <PurchaseNumber label="Additional Bottle quantity" value={line.bottle_quantity} onChange={n => updateLine(index, { bottle_quantity: n ?? 0, ...(!n ? { bottle_unit_price: 0 } : {}) })} invalid={line.bottle_quantity > line.quantity} />}
              {financialsEditable && line.bottle_quantity > 0 && <PurchaseNumber label="Bottle unit price (Tk)" value={line.bottle_unit_price} money onChange={n => updateLine(index, { bottle_unit_price: n ?? 0 })} />}
              {line.bottle_quantity === 0 && <p className="purchase-hint">Use your existing empty bottles for this gas.</p>}
              {line.bottle_quantity > line.quantity && <p role="alert" className="purchase-shortage">Additional bottles cannot exceed Gas quantity.</p>}
            </div></div>
            <div className="purchase-product-footer"><span>Total for {item ? `${item.lpg_brands?.brand_name} ${item.size_kg} kg${item.mouth_size ? ` · ${item.mouth_size}` : ''}` : `product ${index + 1}`}</span>
              <strong>{formatBDT(line.quantity * line.unit_price + line.bottle_quantity * line.bottle_unit_price)}</strong></div>
        </article>;
      })}</div>
      <Pagination {...paging} onChange={paging.setPage} label="product lines" />
    </section>
    <PurchaseFinancials draft={draft} totals={totals} onChange={financialsEditable ? onChange : undefined} />
    <section className="purchase-section"><label className="input-label" htmlFor="purchase-notes">Notes</label>
      <textarea id="purchase-notes" className="input-field" rows={2} value={draft.notes} onChange={event => onChange({ ...draft, notes: event.target.value })} />
    </section>
  </>;
}
