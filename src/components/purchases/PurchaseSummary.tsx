import { usePurchaseActivity } from '../../hooks/usePurchases';
import { purchaseDraft } from '../../lib/purchase';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseFinancials, PurchaseStatuses } from './PurchaseControls';
import type { Purchase } from '../../types/purchase';

const purchaseDate = (date: string | null) => date ? new Date(date).toLocaleString('en-BD', {
  day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit',
}) : 'Pending';

export function PurchaseIdentity({ purchase }: { purchase: Purchase }) {
  return <section className="purchase-section"><PurchaseStatuses purchase={purchase} />
    <dl className="purchase-meta">
      <div><dt>Company</dt><dd>{purchase.company_name ?? 'Historical company not recorded'}</dd></div>
      <div><dt>Plant</dt><dd>{purchase.plant_name}</dd></div>
      <div><dt>Truck</dt><dd>{purchase.truck_name ?? 'Not assigned'}</dd></div>
      <div><dt>Created</dt><dd>{purchaseDate(purchase.created_at)}</dd></div>
      {purchase.dispatched_at && <div><dt>Dispatched</dt><dd>{purchaseDate(purchase.dispatched_at)}</dd></div>}
      {purchase.received_at && <div><dt>Received</dt><dd>{purchaseDate(purchase.received_at)}</dd></div>}
      {purchase.paid_at && <div><dt>Paid</dt><dd>{purchaseDate(purchase.paid_at)}</dd></div>}
      {Number(purchase.operating_cost) > 0 && <div><dt>Logistics operating costs</dt><dd>{formatBDT(Number(purchase.operating_cost))}</dd></div>}
    </dl>
    {purchase.legacy_record && <p className="purchase-hint">Historical purchase. Existing stock and payments are retained; dates and outgoing quantities reflect the earlier workflow.</p>}
    {Number(purchase.operating_cost) > 0 && <p className="purchase-hint">Operating costs are recorded against the logistics wallet separately from purchase transport and labour charges.</p>}
  </section>;
}

export function PurchaseSummary({ purchase, showNotes = true }: { purchase: Purchase; showNotes?: boolean }) {
  return <>
    <section className="purchase-section"><h3>Products & inventory</h3>
      {purchase.items.length ? <div className="purchase-table-wrap"><table className="purchase-summary-table">
        <thead><tr><th scope="col">Product</th><th scope="col">Empties sent</th><th scope="col">Expected</th><th scope="col">Received</th><th scope="col">Billed</th><th scope="col">Unit price</th><th scope="col">Amount</th></tr></thead>
        <tbody>{purchase.items.map(item => <tr key={item.purchase_item_id}>
          <td>{item.brand_name} {item.size_kg} kg {item.mouth_size}<small>{item.type === 'refill' ? 'Refill' : 'New cylinders'}</small></td>
          <td data-label="Empties sent">{item.empty_dispatched}</td><td data-label="Expected">{item.quantity}</td><td data-label="Received">{item.received_quantity ?? 'Pending'}</td><td data-label="Billed">{item.billed_quantity}</td>
          <td data-label="Unit price">{formatBDT(Number(item.unit_price))}</td><td data-label="Amount">{formatBDT(Number(item.line_total))}</td>
        </tr>)}</tbody>
      </table></div> : <p className="purchase-hint">Products have not been added.</p>}
      {purchase.receipt_notes && <p className="purchase-hint">Receipt notes: {purchase.receipt_notes}</p>}
      {purchase.items.some(item => item.received_quantity !== null && item.received_quantity !== item.billed_quantity) &&
        <p className="purchase-alert">Delivery quantities differ from the prepaid bill. Inventory reflects the actual delivery; the settled financial amount is unchanged.</p>}
    </section>
    <PurchaseFinancials draft={purchaseDraft(purchase)} totals={purchase} />
    {showNotes && purchase.notes && <section className="purchase-section"><h3>Notes</h3><p style={{ whiteSpace: 'pre-wrap', fontSize: '.875rem' }}>{purchase.notes}</p></section>}
  </>;
}

const actions: Record<string, string> = {
  created: 'Purchase created', updated: 'Purchase updated', dispatched: 'Truck dispatched',
  received: 'Shipment received', paid: 'Full payment recorded', logistics_updated: 'Shipment operating costs updated', legacy_import: 'Historical purchase retained',
};

export function PurchaseHistory({ purchaseId }: { purchaseId: string }) {
  const query = usePurchaseActivity(purchaseId);
  return <section className="purchase-section"><h3>Activity history</h3>
    {query.isLoading && <p className="purchase-hint">Loading activity…</p>}
    {query.isError && <p role="alert" className="purchase-error">Activity could not be loaded. <button type="button" className="btn btn-ghost" onClick={() => void query.refetch()}>Retry</button></p>}
    <ol className="purchase-activity">{query.data?.map(activity => <li key={activity.activity_id}>
      <strong>{actions[activity.action] ?? 'Purchase activity'}</strong><time dateTime={activity.created_at}>{purchaseDate(activity.created_at)} · {activity.actor_name}</time>
      {typeof activity.details.notes === 'string' && activity.details.notes && <p className="purchase-hint">{activity.details.notes}</p>}
      {typeof activity.details.total_cost === 'number' && <p className="purchase-hint">Settled total: {formatBDT(activity.details.total_cost)}</p>}
      {typeof activity.details.empty_cylinders === 'number' && <p className="purchase-hint">{activity.details.empty_cylinders} empty cylinders dispatched</p>}
      {typeof activity.details.operating_cost === 'number' && <p className="purchase-hint">Operating costs: {formatBDT(activity.details.operating_cost)}</p>}
    </li>)}</ol>
  </section>;
}
