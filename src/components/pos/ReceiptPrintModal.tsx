import { Printer } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { usePrintSale, useReceiptPaperWidth, useSaleReceipt } from '../../hooks/useReceiptPrinter';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { ReceiptPreview } from './ReceiptPreview';
import { ReceiptPrintMethodSelect } from './ReceiptPrintMethodSelect';
import '../purchases/purchases.css';

/** Receipt configuration and preview; opening this dialog never dispatches a print job. */
export function ReceiptPrintModal({ saleId, onClose }: { saleId: string; onClose: () => void }) {
  const { can } = useAuth(); const print = usePrintSale(); const width = useReceiptPaperWidth();
  const query = useSaleReceipt(saleId);
  if (!can('receipts:print')) return null;
  return <PurchaseDialog title="Print receipt" subtitle={`Saved sale #${saleId.slice(0, 8).toUpperCase()}`} onClose={onClose} busy={print.isPending} compact>
    <div className="modal-body" style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr)', gap: '.8rem' }}>
      <ReceiptPrintMethodSelect disabled={print.isPending} />
      {(query.isPending || query.isFetching) && <p role="status">Loading saved receipt…</p>}
      {query.isError && <p role="alert" className="payment-error">Receipt could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
      {query.data && !query.isFetching && !query.isError && <ReceiptPreview width={width} receipt={query.data} />}
    </div><div className="modal-footer"><button className="btn btn-secondary" onClick={onClose} disabled={print.isPending}>Close</button><button className="btn btn-secondary" disabled={query.isFetching || print.isPending} onClick={() => void query.refetch()}>Refresh receipt</button><button className="btn btn-primary" disabled={print.isPending || !query.data || query.isFetching || query.isError} onClick={() => print.mutate(saleId)}><Printer size={15} />{print.isPending ? 'Printing…' : 'Print receipt'}</button></div>
  </PurchaseDialog>;
}
