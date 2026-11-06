import { useListPage } from '../../hooks/useListPage';
import { Pagination, PageNavigation } from '../ui/Pagination';
import { useState } from 'react';
import { usePurchaseActivity } from '../../hooks/usePurchases';
import { purchaseDraft, purchaseDate } from '../../lib/purchase';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseFinancials, PurchaseStatuses } from './PurchaseControls';
import type { Purchase } from '../../types/purchase';
import { ProductImage } from '../inventory/ProductImage';

export function PurchaseIdentity({ purchase }: { purchase: Purchase }) {
  return <section className="purchase-section"><PurchaseStatuses purchase={purchase} />
    <dl className="purchase-meta">
      <div><dt>{purchase.business_category === 'stove' ? 'Supplier' : 'Company'}</dt><dd>{purchase.business_category === 'stove' ? purchase.supplier_name : purchase.company_name ?? 'Historical company not recorded'}</dd></div>
      {purchase.business_category === 'stove' ? <div><dt>Delivery</dt><dd>Direct inventory receipt</dd></div> : <>
        <div><dt>Plant</dt><dd>{purchase.plant_name}</dd></div>
        <div><dt>Vehicle</dt><dd>{purchase.vehicle_name ?? 'Not assigned'}</dd></div>
      </>}
      <div><dt>Created</dt><dd>{purchaseDate(purchase.created_at)}</dd></div>
      {purchase.dispatched_at && <div><dt>Dispatched</dt><dd>{purchaseDate(purchase.dispatched_at)}</dd></div>}
      {purchase.received_at && <div><dt>Received</dt><dd>{purchaseDate(purchase.received_at)}</dd></div>}
      {purchase.paid_at && <div><dt>Paid</dt><dd>{purchaseDate(purchase.paid_at)}</dd></div>}
      {Number(purchase.operating_cost) > 0 && <div><dt>Logistics operating costs</dt><dd>{formatBDT(Number(purchase.operating_cost))}</dd></div>}
    </dl>
    {Number(purchase.operating_cost) > 0 && <p className="purchase-hint">Transit costs are incurred separately and paid from real wallets. The purchase transport charge is an internal revenue allocation.</p>}
  </section>;
}

export function PurchaseSummary({ purchase, showNotes = true }: { purchase: Purchase; showNotes?: boolean }) {
  const paging = useListPage(purchase.items, 8, purchase.purchase_id);
  return <>
    <section className="purchase-section"><h3>Products & inventory</h3>
      {purchase.items.length ? <div className="purchase-table-wrap"><table className="purchase-summary-table">
        <thead><tr><th scope="col">Product</th>{purchase.business_category !== 'stove' && <th scope="col">Empties sent</th>}<th scope="col">Expected</th><th scope="col">Received</th><th scope="col">Unit price</th><th scope="col">Amount</th></tr></thead>
        <tbody>{paging.entries.map(item => <tr key={item.purchase_item_id}>
          <td><div className="product-with-image">{item.image_url && <ProductImage path={item.image_url} name={item.product_name || item.brand_name} />}<div>{item.product_name || `${item.brand_name} ${item.size_kg} kg ${item.mouth_size ?? ''}`}<small>{purchase.business_category === 'stove' ? 'Product' : `${item.quantity} Gas + ${item.bottle_quantity} Bottle`}</small></div></div></td>
          {purchase.business_category !== 'stove' && <td data-label="Empties sent">{item.empty_dispatched}</td>}<td data-label="Expected">{item.quantity}</td><td data-label="Received">{purchase.status === 'received' ? item.quantity : 'Pending'}</td>
          <td data-label="Unit price">{formatBDT(Number(item.unit_price))}{purchase.business_category !== 'stove' && <small>Bottle: {formatBDT(Number(item.bottle_unit_price))}</small>}</td><td data-label="Amount">{formatBDT(Number(item.line_total))}</td>
        </tr>)}</tbody>
      </table></div> : <p className="purchase-hint">Products have not been added.</p>}
      <Pagination {...paging} onChange={paging.setPage} label="purchase lines" />
      {purchase.receipt_notes && <p className="purchase-hint">Receipt notes: {purchase.receipt_notes}</p>}

    </section>
    <PurchaseFinancials draft={purchaseDraft(purchase)} totals={purchase} businessCategory={purchase.business_category} />
    {showNotes && purchase.notes && <section className="purchase-section"><h3>Notes</h3><p style={{ whiteSpace: 'pre-wrap', fontSize: '.875rem' }}>{purchase.notes}</p></section>}
  </>;
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
    {!query.isError && <ol className="purchase-activity">{entries.map(activity => {
      const title = activity.kind === 'payment' ? 'Purchase payment recorded' : activity.kind === 'refund' ? 'Purchase refund recorded' : 'Purchase activity';
      return <li className="history-card" key={`${activity.kind}:${activity.activity_id}`} data-activity-id={activity.activity_id}>
        <div className="purchase-activity-heading"><strong>{title}</strong><time dateTime={activity.created_at}>{purchaseDate(activity.created_at)}</time></div>
        <span className="purchase-activity-actor">{activity.actor_name}</span>
        {activity.kind === 'activity' ? <p className="purchase-activity-message">{activity.message}</p> : <>
        <p className="purchase-activity-total">{activity.kind === 'refund' ? '+' : '−'}{formatBDT(Number(activity.amount))}</p>
        {activity.wallet_entries.map(entry => <div className="purchase-activity-wallet" key={entry.transaction_id} data-transaction-id={entry.transaction_id}>
          <div><strong>{entry.wallet_name}</strong><strong>{entry.amount > 0 ? '+' : '−'}{formatBDT(Math.abs(entry.amount))}</strong></div>
          <small>{entry.description}{entry.reference && ` · Ref: ${entry.reference}`}</small>
          <details><summary>Audit references</summary><p className="purchase-hint">{purchaseDate(entry.created_at)}<br />Method: {entry.method}<br />Ledger: {entry.transaction_id}{entry.purchase_payment_id && <><br />Payment: {entry.purchase_payment_id}</>}{entry.operation_id && <><br />Operation: {entry.operation_id}</>}</p></details>
        </div>)}
        </>}
      </li>;
    })}</ol>}
    <PageNavigation page={query.data?.page ?? page} hasMore={!query.isError && (query.data?.hasMore ?? false)} busy={query.isFetching}
      onChange={setPage} label="Activity history" alwaysVisible />
  </section>;
}
