import { Plus, Trash2, Package } from 'lucide-react';
import { useItems } from '../../hooks/useInventory';
import { useTrucks } from '../../hooks/useLogistics';
import { PurchaseNumber, PurchaseSelect, PurchaseFinancials } from './PurchaseControls';
import { purchaseTotals } from '../../lib/purchase';
import { formatBDT } from '../../lib/formatBDT';
import type { Purchase, PurchaseDraft, PurchaseLinePayload } from '../../types/purchase';

export function PurchaseShipment({ draft, onChange }: { draft: PurchaseDraft; onChange: (draft: PurchaseDraft) => void }) {
  const trucksQuery = useTrucks();
  const trucks = (trucksQuery.data ?? []).filter(truck => truck.status === 'idle' || truck.truck_id === draft.truck_id);
  return <div>
    <PurchaseSelect label="Truck (optional until dispatch)" value={draft.truck_id ?? ''} onChange={id => onChange({ ...draft, truck_id: id || null })}
      placeholder={trucksQuery.isLoading ? 'Loading trucks…' : 'Assign an idle truck'}
      options={[{ value: '', label: 'Assign later' }, ...trucks.map(truck => ({ value: truck.truck_id, label: truck.name, description: truck.serial_no }))]} />
    {trucksQuery.isError && <p role="alert" className="purchase-error">Trucks could not be loaded. <button type="button" className="btn btn-ghost" onClick={() => void trucksQuery.refetch()}>Retry</button></p>}
  </div>;
}

export function PurchaseForm({ draft, onChange, companyId, purchase, showShipment = true }: {
  draft: PurchaseDraft; onChange: (draft: PurchaseDraft) => void; companyId: string | null; purchase?: Purchase; showShipment?: boolean;
}) {
  const itemsQuery = useItems();
  const items = (itemsQuery.data ?? []).filter(item => item.brand_id === companyId);
  const productsEditable = !purchase || purchase.status === 'created';
  const financialsEditable = !purchase || purchase.payment_status === 'unpaid';
  const totals = purchaseTotals(draft.items, draft.commission, draft.transport_cost, draft.labour_cost, purchase);
  function updateLine(index: number, patch: Partial<PurchaseLinePayload>) {
    onChange({ ...draft, items: draft.items.map((line, i) => {
      if (i !== index) return line;
      const updated = { ...line, ...patch };
      return { ...updated, empty_dispatched: updated.type === 'refill' ? updated.quantity : 0 };
    }) });
  }
  return <>
    {productsEditable && showShipment && <section className="purchase-section"><h3>Shipment</h3>
      <PurchaseShipment draft={draft} onChange={onChange} />
    </section>}
    <section className="purchase-section">
      <div className="purchase-section-heading"><div><h3>Products & cylinders</h3>
        <p className="purchase-hint">{productsEditable ? 'Refills exchange one empty per cylinder. Stock moves on dispatch and receipt.' : 'Products and expected quantities are locked after dispatch.'}</p></div>
        {productsEditable && <button type="button" className="btn btn-secondary" disabled={!companyId} onClick={() => onChange({ ...draft,
          items: [...draft.items, { item_id: '', type: 'refill', quantity: 1, empty_dispatched: 1, unit_price: 0 }],
        })}><Plus size={15} /> Add product</button>}
      </div>
      {itemsQuery.isError && productsEditable && <p role="alert" className="purchase-error">Products could not be loaded. <button type="button" className="btn btn-ghost" onClick={() => void itemsQuery.refetch()}>Retry</button></p>}
      {!draft.items.length && <div className="purchase-empty"><Package size={22} /><p>Products can be added later.</p></div>}
      <div className="purchase-lines">{draft.items.map((line, index) => {
        const item = items.find(item => item.item_id === line.item_id);
        const saved = purchase?.items.find(item => item.purchase_item_id === line.purchase_item_id);
        return <article className={`purchase-line${productsEditable ? ' purchase-line-editable' : ''}`} key={line.purchase_item_id ?? index}>
            {productsEditable ? <PurchaseSelect label={`Product ${index + 1}`} value={line.item_id} onChange={id => updateLine(index, { item_id: id })}
              options={items.filter(item => !draft.items.some((other, i) => i !== index && other.item_id === item.item_id && other.type === line.type))
                .map(item => ({ value: item.item_id, label: `${item.lpg_brands?.brand_name ?? item.brand} ${item.size_kg} kg${item.mouth_size ? ` · ${item.mouth_size}` : ''}`,
                  description: `${item.empty_quantity} empty cylinders available` }))} />
              : <strong>{saved?.brand_name} {saved?.size_kg} kg {saved?.mouth_size}</strong>}
            {productsEditable && <fieldset className="purchase-kind"><legend className="input-label">Purchase type</legend>
              <div className="purchase-segmented">
                <button type="button" aria-pressed={line.type === 'refill'} disabled={draft.items.some((other, i) => i !== index && !!line.item_id && other.item_id === line.item_id && other.type === 'refill')} onClick={() => updateLine(index, { type: 'refill' })}>Refill</button>
                <button type="button" aria-pressed={line.type === 'package'} disabled={draft.items.some((other, i) => i !== index && !!line.item_id && other.item_id === line.item_id && other.type === 'package')} onClick={() => updateLine(index, { type: 'package' })}>New</button>
              </div></fieldset>}
            {productsEditable ?
              <PurchaseNumber label={line.type === 'refill' ? 'Expected refills' : 'Expected new cylinders'} value={line.quantity}
                onChange={n => updateLine(index, { quantity: n ?? 0 })} hint={line.type === 'refill' && item ? `${item.empty_quantity} empties available` : undefined} />
             : <dl className="purchase-line-quantities">
              <div><dt>Expected</dt><dd>{line.quantity}</dd></div><div><dt>Empties sent</dt><dd>{line.empty_dispatched}</dd></div>
              <div><dt>Received</dt><dd>{saved?.received_quantity ?? 'Pending'}</dd></div><div><dt>Billed</dt><dd>{saved?.billed_quantity}</dd></div>
            </dl>}
            {financialsEditable ? <PurchaseNumber label="Unit price (Tk)" value={line.unit_price} money onChange={n => updateLine(index, { unit_price: n ?? 0 })} />
              : <div><span className="purchase-hint">Unit price</span><p>{formatBDT(line.unit_price)}</p></div>}
            <div className="purchase-line-total"><span className="purchase-hint">Line total</span>
              <strong>{formatBDT((productsEditable ? line.quantity : saved?.billed_quantity ?? line.quantity) * line.unit_price)}</strong></div>
            {productsEditable ? <button type="button" className="btn btn-ghost purchase-remove" aria-label={`Remove product ${index + 1}`}
              onClick={() => onChange({ ...draft, items: draft.items.filter((_, i) => i !== index) })}><Trash2 size={16} /></button>
              : <span className="purchase-hint">{line.type === 'refill' ? 'Refill' : 'New cylinders'}</span>}
        </article>;
      })}</div>
    </section>
    <PurchaseFinancials draft={draft} totals={totals} onChange={financialsEditable ? onChange : undefined} />
    <section className="purchase-section"><label className="input-label" htmlFor="purchase-notes">Notes</label>
      <textarea id="purchase-notes" className="input-field" rows={2} value={draft.notes} onChange={event => onChange({ ...draft, notes: event.target.value })} />
    </section>
  </>;
}
