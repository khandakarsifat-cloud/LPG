import { useListPage } from '../../hooks/useListPage';
import { Pagination } from '../ui/Pagination';
import { useState } from 'react';
import { usePurchaseActivity } from '../../hooks/usePurchases';
import { purchaseDraft } from '../../lib/purchase';
import { describePurchaseActivity } from '../../lib/purchaseActivity';
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
  const paging = useListPage(purchase.items, 8, purchase.purchase_id);
  return <>
    <section className="purchase-section"><h3>Products & inventory</h3>
      {purchase.items.length ? <div className="purchase-table-wrap"><table className="purchase-summary-table">
        <thead><tr><th scope="col">Product</th><th scope="col">Empties sent</th><th scope="col">Expected</th><th scope="col">Received</th><th scope="col">Billed</th><th scope="col">Unit price</th><th scope="col">Amount</th></tr></thead>
        <tbody>{paging.entries.map(item => <tr key={item.purchase_item_id}>
          <td>{item.brand_name} {item.size_kg} kg {item.mouth_size}<small>{item.type === 'refill' ? 'Refill' : 'New cylinders'}</small></td>
          <td data-label="Empties sent">{item.empty_dispatched}</td><td data-label="Expected">{item.quantity}</td><td data-label="Received">{item.received_quantity ?? 'Pending'}</td><td data-label="Billed">{item.billed_quantity}</td>
          <td data-label="Unit price">{formatBDT(Number(item.unit_price))}</td><td data-label="Amount">{formatBDT(Number(item.line_total))}</td>
        </tr>)}</tbody>
      </table></div> : <p className="purchase-hint">Products have not been added.</p>}
      <Pagination {...paging} onChange={paging.setPage} label="purchase lines" />
      {purchase.receipt_notes && <p className="purchase-hint">Receipt notes: {purchase.receipt_notes}</p>}
      {purchase.items.some(item => item.received_quantity !== null && item.received_quantity !== item.billed_quantity) &&
        <p className="purchase-alert">Delivery quantities differ from the prepaid bill. Inventory reflects the actual delivery; the settled financial amount is unchanged.</p>}
    </section>
    <PurchaseFinancials draft={purchaseDraft(purchase)} totals={purchase} />
    {showNotes && purchase.notes && <section className="purchase-section"><h3>Notes</h3><p style={{ whiteSpace: 'pre-wrap', fontSize: '.875rem' }}>{purchase.notes}</p></section>}
  </>;
}

function ActivityLines({ lines, label }: { lines: string[]; label: string }) {
  const paging = useListPage(lines, 8);
  return <><ul className="purchase-activity-changes">{paging.entries.map((line, index) => <li key={index}>{line}</li>)}</ul><Pagination {...paging} onChange={paging.setPage} label={label} /></>;
}

export function PurchaseHistory({ purchase }: { purchase: Purchase }) {
  const [page, setPage] = useState(0);
  const query = usePurchaseActivity(purchase.purchase_id, page);
  const entries = query.data?.entries ?? [];
  return <section className="purchase-section purchase-history" aria-label="Activity history" aria-busy={query.isFetching}>
    <div className="purchase-section-heading"><h3>Activity history</h3><span className="purchase-hint">Oldest first · 6 per page</span></div>
    {query.isLoading && <p className="purchase-hint">Loading activity…</p>}
    {query.isError && <p role="alert" className="purchase-error">Activity could not be loaded. <button type="button" className="btn btn-ghost" onClick={() => void query.refetch()}>Retry</button></p>}
    {!query.isError && !query.isLoading && entries.length === 0 && <p className="purchase-hint">No activity on this page.</p>}
    {!query.isError && <ol className="purchase-activity">{entries.map((activity, index) => {
      const previous = entries.slice(0, index).reverse().find(entry => Array.isArray(entry.details?.items));
      const summary = describePurchaseActivity(activity, purchase, previous?.details.items);
      return <li key={activity.activity_id}>
        <div className="purchase-activity-heading"><strong>{summary.title}</strong><time dateTime={activity.created_at}>{purchaseDate(activity.created_at)}</time></div>
        <span className="purchase-activity-actor">{activity.actor_name}</span>
        <ul className="purchase-activity-changes">{summary.changes.slice(0, 3).map((change, i) => <li key={i}>{change}</li>)}</ul>
        {summary.changes.length > 3 && <details><summary>{summary.changes.length - 3} more changes</summary>
          <ActivityLines lines={summary.changes.slice(3)} label="changes" />
        </details>}
        {summary.snapshots.length > 0 && <details><summary>Saved products ({summary.snapshots.length})</summary>
          <ActivityLines lines={summary.snapshots} label="saved products" />
        </details>}
      </li>;
    })}</ol>}
    <nav className="purchase-history-pagination" aria-label="Activity history pages">
      <button type="button" className="btn btn-secondary" disabled={page === 0 || query.isFetching} onClick={() => setPage(page - 1)}>Previous</button>
      <span role="status">Page {page + 1}</span>
      <button type="button" className="btn btn-secondary" disabled={!query.data?.hasMore || query.isFetching || query.isError} onClick={() => setPage(page + 1)}>Next</button>
    </nav>
  </section>;
}
