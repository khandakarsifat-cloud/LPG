import { useListPage } from '../../hooks/useListPage';
import { ArrowLeft, Box } from 'lucide-react';
import { useSaleDetails } from '../../hooks/useDashboard';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { customerDay } from '../../lib/customer';
import { formatBDQty, formatBDT } from '../../lib/formatBDT';
import './transactions.css';

/** Saved transaction inspection, independent of POS receipt and printer controls. */
export function TransactionDetailsModal({ saleId, onClose, returnLabel = 'Back' }: { saleId: string; onClose: () => void; returnLabel?: string }) {
  const query = useSaleDetails(saleId); const sale = query.data;
  const lines = sale?.sale_items ?? [];
  const paging = useListPage(lines, 6, saleId);
  const refill = lines.filter(line => line.type === 'refill').reduce((sum, line) => sum + line.quantity, 0);
  const packages = lines.filter(line => line.type === 'package').reduce((sum, line) => sum + line.quantity, 0);
  const empties = lines.filter(line => line.type === 'empty_return').reduce((sum, line) => sum + line.quantity, 0) - packages;
  return <PurchaseDialog title={`Transaction #${saleId.slice(0, 8).toUpperCase()}`} subtitle={sale ? `${customerDay(sale.created_at)} · ${new Date(sale.created_at).toLocaleTimeString('en-BD', { timeZone: 'Asia/Dhaka', hour: 'numeric', minute: '2-digit' })}` : 'Saved transaction details'} className="transaction-detail-dialog" onClose={onClose}>
    <div className="modal-body">
      {query.isPending && <p role="status" className="transaction-empty">Loading transaction…</p>}
      {query.isError && <p role="alert" className="purchase-error">This transaction could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
      {sale && <>
        <div className="transaction-badges"><span className="transaction-badge success">Completed</span><span className="transaction-badge">{sale.sale_tier === 'wholesale' ? 'Wholesale' : 'Retail'} sale</span></div>
        <div className="transaction-info-grid"><section><span>Customer</span><strong>{sale.customers?.shop_name && sale.sale_tier === 'wholesale' ? sale.customers.shop_name : sale.customers?.name || 'Customer unavailable'}</strong><p>{sale.customers?.name} {sale.customers?.phone && ` · ${sale.customers.phone}`}</p>{sale.customers?.address && <p>{sale.customers.address}</p>}</section>
          <section className="transaction-record"><div><span>Recorded by</span><strong>{sale.user_profiles?.full_name || sale.user_profiles?.email || 'Unavailable'}</strong></div><div><span>Payment</span><strong>Paid in full</strong></div><div><span>Sale type</span><strong>{sale.sale_tier === 'wholesale' ? 'Wholesale' : 'Retail'}</strong></div></section></div>
        <div className="transaction-section-heading"><h3>Products</h3><span>{formatBDQty(refill)} refills + {formatBDQty(packages)} packages</span></div>
        <div className="transaction-line-head"><span>Product</span><span>Qty</span><span className="transaction-unit-price">Unit price</span><span>Amount</span></div>
        {paging.entries.map((line, index) => <div className="transaction-line" key={paging.page * paging.pageSize + index}>
          <div><strong>{line.items?.lpg_brands?.brand_name || line.items?.brand || 'Product unavailable'} {line.items?.size_kg && `${line.items.size_kg} kg`}</strong><p>{line.items?.mouth_size}<span className={`transaction-badge ${line.type === 'empty_return' ? 'neutral' : ''}`}>{line.type === 'refill' ? 'Refill' : line.type === 'package' ? 'Package' : 'Empty return'}</span></p><small className="transaction-mobile-price">{line.type === 'empty_return' ? 'No charge' : `${formatBDT(Number(line.unit_price))} each`}</small></div>
          <span>×{formatBDQty(line.quantity)}</span><span className="transaction-unit-price">{line.type === 'empty_return' ? '—' : formatBDT(Number(line.unit_price))}</span><strong>{line.type === 'empty_return' ? '—' : formatBDT(Number(line.line_total))}</strong>
        </div>)}
        <Pagination {...paging} onChange={paging.setPage} label="product lines" />
        <div className="transaction-totals-area">{sale.notes ? <div className="transaction-note"><strong>Note</strong><p>{sale.notes}</p></div> : <div />}
          <dl className="transaction-totals"><div><dt>Subtotal</dt><dd>{formatBDT(Number(sale.subtotal))}</dd></div><div><dt>Discount</dt><dd>− {formatBDT(Number(sale.discount_amount))}</dd></div><div><dt>Exchange fee</dt><dd>{formatBDT(Number(sale.exchange_fee))}</dd></div><div className="transaction-grand-total"><dt>Total paid</dt><dd>{formatBDT(Number(sale.total_amount))}</dd></div></dl></div>
        <p className="transaction-stock-note"><Box size={15} />Stock movement: {formatBDQty(refill + packages)} filled out · {formatBDQty(Math.abs(empties))} net empties {empties >= 0 ? 'in' : 'out'}</p>
      </>}
    </div><div className="modal-footer"><small>Amounts saved at checkout</small><button className="btn btn-secondary" onClick={onClose}><ArrowLeft size={14} />{returnLabel}</button></div>
  </PurchaseDialog>;
}
