import { SaleReversal } from '../finance/SaleReversal';
import { useListPage } from '../../hooks/useListPage';
import { useState } from 'react';
import { ArrowLeft, Box } from 'lucide-react';
import { useSaleDetails } from '../../hooks/useDashboard';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { customerDay } from '../../lib/customer';
import { formatBDQty, formatBDT } from '../../lib/formatBDT';
import './transactions.css';
import { SalePayments } from '../finance/SalePayments';
import { SaleBottles } from './SaleBottles';
import { useSaleBottles } from '../../hooks/useSales';
import { useAuth } from '../../contexts/AuthContext';
import { ReceiptPrintModal } from '../pos/ReceiptPrintModal';
import { ProductImage } from '../inventory/ProductImage';

/** Saved transaction inspection, independent of POS receipt and printer controls. */
export function TransactionDetailsModal({ saleId, onClose, returnLabel = 'Back' }: { saleId: string; onClose: () => void; returnLabel?: string }) {
  const query = useSaleDetails(saleId); const sale = query.data;
  const bottles = useSaleBottles(saleId); const { can } = useAuth();
  const [printOpen, setPrintOpen] = useState(false);
  const stove = sale?.business_category === 'stove';
  const lines = sale?.sale_items ?? [];
  const paging = useListPage(lines, 6, saleId);
  const refill = lines.filter(line => line.type === 'refill').reduce((sum, line) => sum + line.quantity, 0);
  const packages = lines.filter(line => line.type === 'package').reduce((sum, line) => sum + line.quantity, 0);
  return <><PurchaseDialog title={`Transaction #${saleId.slice(0, 8).toUpperCase()}`} subtitle={sale ? `${customerDay(sale.created_at)} · ${new Date(sale.created_at).toLocaleTimeString('en-BD', { timeZone: 'Asia/Dhaka', hour: 'numeric', minute: '2-digit' })}` : 'Saved transaction details'} className="transaction-detail-dialog" onClose={onClose}>
    <div className="modal-body">
      {query.isPending && <p role="status" className="transaction-empty">Loading transaction…</p>}
      {query.isError && <p role="alert" className="purchase-error">This transaction could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
      {sale && <>
        <div className="transaction-badges"><span className="transaction-badge">{stove ? 'Stove' : 'LPG'}</span><span className={`transaction-badge ${sale.status === 'voided' ? 'neutral' : 'success'}`}>{sale.status === 'voided' ? 'Cancelled' : 'Completed'}</span><span className="transaction-badge">{sale.sale_tier === 'wholesale' ? 'Wholesale' : 'Retail'} sale</span></div>
        <div className="transaction-info-grid"><section><span>Customer</span><strong>{sale.customers?.shop_name && sale.sale_tier === 'wholesale' ? sale.customers.shop_name : sale.customers?.name || 'Customer unavailable'}</strong><p>{sale.customers?.name} {sale.customers?.phone && ` · ${sale.customers.phone}`}</p>{sale.customers?.address && <p>{sale.customers.address}</p>}</section>
          <section className="transaction-record"><div><span>Recorded by</span><strong>{sale.user_profiles?.full_name || sale.user_profiles?.email || 'Unavailable'}</strong></div><div><span>Sale type</span><strong>{sale.sale_tier === 'wholesale' ? 'Wholesale' : 'Retail'}</strong></div></section></div>
        <div className="transaction-section-heading"><h3>Products</h3><span>{stove ? `${formatBDQty(lines.reduce((sum, line) => sum + line.quantity, 0))} items · ${formatBDQty(lines.length)} ${lines.length === 1 ? 'product' : 'products'}` : `${formatBDQty(refill)} refills + ${formatBDQty(packages)} packages`}</span></div>
        <div className="transaction-line-head"><span>Product</span><span>Qty</span><span className="transaction-unit-price">Unit price</span><span>Amount</span></div>
        {paging.entries.map((line, index) => <div className="transaction-line" key={paging.page * paging.pageSize + index}>
          <div className="product-with-image">{line.items?.image_url && <ProductImage path={line.items.image_url} name={line.items.product_name || line.items.lpg_brands?.brand_name || 'Product'} />}<div><strong>{line.items?.product_name || `${line.items?.lpg_brands?.brand_name ?? 'Product unavailable'} ${line.items?.size_kg ?? ''} kg`}</strong><p>{!stove && line.items?.mouth_size}<span className={`transaction-badge ${line.type === 'empty_return' ? 'neutral' : ''}`}>{stove ? 'Stove product' : line.type === 'refill' ? 'Refill' : line.type === 'package' ? 'Package' : 'Expected empty'}</span></p><small className="transaction-mobile-price">{line.type === 'empty_return' ? 'No charge' : `${formatBDT(Number(line.unit_price))} each`}</small></div></div>
          <span className="transaction-line-quantity">×{formatBDQty(line.quantity)}</span><span className="transaction-unit-price">{line.type === 'empty_return' ? '—' : formatBDT(Number(line.unit_price))}</span><strong>{line.type === 'empty_return' ? '—' : formatBDT(Number(line.line_total))}</strong>
        </div>)}
        <Pagination {...paging} onChange={paging.setPage} label="product lines" />
        <div className={`transaction-totals-area${sale.notes ? '' : ' transaction-totals-area--no-note'}`}>{sale.notes ? <div className="transaction-note"><strong>Note</strong><p>{sale.notes}</p></div> : null}
          <dl className="transaction-totals"><div><dt>Subtotal</dt><dd>{formatBDT(Number(sale.subtotal))}</dd></div><div><dt>Discount</dt><dd>− {formatBDT(Number(sale.discount_amount))}</dd></div>{!stove && <div><dt>Exchange cost</dt><dd>{formatBDT(Number(sale.exchange_fee))}</dd></div>}<div className="transaction-grand-total"><dt>Sale total</dt><dd>{formatBDT(Number(sale.total_amount))}</dd></div></dl></div>
        <SalePayments saleId={sale.sale_id} showHistory={false} />
        {sale.business_category !== 'stove' && sale.status !== 'voided' && <SaleBottles saleId={sale.sale_id} />}
        {sale.business_category !== 'stove' && <p className="transaction-stock-note"><Box size={15} />Stock movement: {formatBDQty(refill + packages)} filled out · {bottles.isPending ? 'Loading physical empties…' : bottles.isError || !bottles.data ? 'Physical empty count unavailable' : `${formatBDQty(bottles.data.received)} empty bottles physically received · ${formatBDQty(packages)} empties out for packages`}</p>}
      </>}
    </div><div className="modal-footer"><div className="transaction-reversal-actions">{sale && <SaleReversal saleId={sale.sale_id} />}</div><div className="transaction-footer-actions">{can('receipts:print') && <button className="btn btn-secondary" disabled={!sale || sale.status === 'voided'} onClick={() => setPrintOpen(true)}>Print receipt</button>}<button className="btn btn-secondary" onClick={onClose}><ArrowLeft size={14} />{returnLabel}</button></div></div>
  </PurchaseDialog>{printOpen && can('receipts:print') && <ReceiptPrintModal saleId={saleId} onClose={() => setPrintOpen(false)} />}</>;
}
