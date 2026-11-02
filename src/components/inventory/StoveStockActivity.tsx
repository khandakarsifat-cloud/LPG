import { lazy, Suspense, useState } from 'react';
import { usePurchaseDetails } from '../../hooks/usePurchases';
import { useAuth } from '../../contexts/AuthContext';
import { useInventoryHistory } from '../../hooks/useInventory';
import { inventoryMovementSource } from '../../lib/inventoryMovement';
import { PurchaseDialog } from '../purchases/PurchaseControls';
const Sale = lazy(() => import('../transactions/TransactionDetailsModal').then(m => ({ default: m.TransactionDetailsModal })));
const Purchase = lazy(() => import('../purchases/UpdatePurchaseModal').then(m => ({ default: m.UpdatePurchaseModal })));

export function StoveStockActivity({ itemId }: { itemId: string }) {
 const [page, setPage] = useState(0); const [record, setRecord] = useState<{ kind: 'sale' | 'purchase'; id: string } | null>(null);
 const { can } = useAuth(); const q = useInventoryHistory({ source: 'all', itemIds: [itemId], page, from: '', to: '' });
 return <section className="stove-stock-activity"><header><h3>Stock activity</h3><span className="finance-note">Quantities in units</span></header>
  {q.isPending && <p role="status">Loading stock activity…</p>}{q.error && <p className="payment-error" role="alert">{q.error.message}</p>}
  {q.data?.entries.map(e => { const source = inventoryMovementSource(e); const sourceId = source.id, sourceKind = source.kind; const label = e.reference_type === 'sale_reversal' ? 'Sale cancelled' : source.kind === 'sale' ? 'Sale' : e.reference_type === 'stove_purchase_receipt' ? 'Purchase received' : e.reference_type === 'stove_purchase_cancellation' ? 'Purchase returned' : e.reference_type === 'opening' ? 'Opening stock' : e.filled_quantity_change > 0 ? 'Stock added' : 'Stock removed';
   const allowed = source.kind === 'sale' ? can('sales:view') || can('receipts:print') : source.kind === 'purchase' && (can('purchases:view') || can('purchases:manage'));
   return <article className="stove-stock-row" key={e.movement_id}><div><strong>{label}</strong><small>{new Date(e.created_at).toLocaleDateString('en-BD', { timeZone: 'Asia/Dhaka', day: 'numeric', month: 'short', year: 'numeric' })}{e.saleCustomer ? ` · ${e.saleCustomer}` : ''}</small></div><strong className={e.filled_quantity_change < 0 ? 'stock-out' : 'stock-in'}>{e.filled_quantity_change > 0 ? '+' : ''}{e.filled_quantity_change} units</strong>{allowed && sourceId && sourceKind && <button className="btn btn-secondary" onClick={() => setRecord({ id: sourceId, kind: sourceKind })}>View {source.kind}</button>}</article>;
  })}
  {q.data?.entries.length === 0 && <p className="finance-empty">No stock activity yet.</p>}
  <div className="stove-activity-pagination"><button className="btn btn-secondary" disabled={page === 0 || q.isFetching} onClick={() => setPage(p => p - 1)}>Previous</button><span>Page {page + 1}</span><button className="btn btn-secondary" disabled={!q.data?.hasMore || q.isFetching} onClick={() => setPage(p => p + 1)}>Next</button></div>
  {record && <Suspense fallback={<PurchaseDialog title="Loading record" onClose={() => setRecord(null)}><div className="modal-body">Loading…</div></PurchaseDialog>}>{record.kind === 'sale' ? <Sale saleId={record.id} onClose={() => setRecord(null)} /> : <StovePurchase id={record.id} onClose={() => setRecord(null)} />}</Suspense>}
 </section>;
}

function StovePurchase({ id, onClose }: { id: string; onClose: () => void }) {
 const q = usePurchaseDetails(id);
 return q.data ? <Purchase open purchase={q.data} onClose={onClose} /> : <PurchaseDialog title="Purchase" onClose={onClose}><div className="modal-body">{q.error ? <p role="alert">{q.error.message}</p> : <p role="status">Loading purchase…</p>}</div></PurchaseDialog>;
}
