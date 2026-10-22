import { Printer } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { usePrintSale, useReceiptPaperWidth } from '../../hooks/useReceiptPrinter';
import { useSaleDetails, type SaleTransaction } from '../../hooks/useDashboard';
import { useSaleSettlement } from '../../hooks/useFinance';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { ReceiptPreview } from '../pos/ReceiptPreview';
import { ReceiptPrintMethodSelect } from '../pos/ReceiptPrintMethodSelect';
import { SalePayments } from '../finance/SalePayments';
import { buildSaleReceipt } from '../../lib/receipt';
import '../purchases/purchases.css';

export function SaleDetailsModal({ isOpen, onClose, sale }: { isOpen: boolean; onClose: () => void; sale: SaleTransaction | null }) {
  const { profile, can } = useAuth(); const print = usePrintSale(); const width = useReceiptPaperWidth();
  const query = useSaleDetails(isOpen ? sale?.sale_id ?? null : null); const settlement = useSaleSettlement(isOpen ? sale?.sale_id ?? null : null);
  if (!isOpen || !sale) return null;
  const saved = query.data; const payment = settlement.data;
  return <PurchaseDialog title="POS sale details" subtitle={`Saved sale #${sale.sale_id.slice(0, 8).toUpperCase()}`} onClose={onClose} busy={print.isPending} compact>
    <div className="modal-body" style={{ display: 'grid', gap: '.8rem' }}>
      {can('receipts:print') && <ReceiptPrintMethodSelect disabled={print.isPending} />}
      {(query.isPending || settlement.isPending) && <p role="status">Loading saved receipt…</p>}
      {(query.error || settlement.error) && <p role="alert" className="payment-error">Receipt could not be loaded. <button className="btn btn-secondary" onClick={() => { void query.refetch(); void settlement.refetch(); }}>Retry</button></p>}
      {saved && payment && <ReceiptPreview width={width} receipt={buildSaleReceipt(saved, payment, profile?.business_name)} />}
      <SalePayments saleId={sale.sale_id} />
    </div><div className="modal-footer"><button className="btn btn-secondary" onClick={onClose} disabled={print.isPending}>Close</button>{can('receipts:print') && <button className="btn btn-primary" disabled={print.isPending || !saved || !payment} onClick={() => print.mutate(sale.sale_id)}><Printer size={15} />{print.isPending ? 'Printing…' : 'Print Receipt Again'}</button>}</div>
  </PurchaseDialog>;
}
