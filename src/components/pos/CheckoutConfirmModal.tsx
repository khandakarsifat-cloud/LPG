import { useState } from 'react';
import { ChevronDown, CheckCircle2, Printer } from 'lucide-react';
import type { POSSalePayload } from '../../hooks/usePOS';
import type { POSCustomerDraft } from './CustomerSelection';
import type { PaymentDraft, PaymentInput } from '../../types/finance';
import { useInventoryBalances } from '../../hooks/useInventory';
import { useAuth } from '../../contexts/AuthContext';
import { usePaymentWallets } from '../../hooks/useFinance';
import { useReceiptPaperWidth } from '../../hooks/useReceiptPrinter';
import { paymentDraft, validatePayments } from '../../lib/payments';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { ReceiptPrintMethodSelect } from './ReceiptPrintMethodSelect';
import { PaymentEntries } from './PaymentEntries';
import { ReceiptPreview } from './ReceiptPreview';
import '../purchases/purchases.css';

interface CheckoutConfirmModalProps {
  isOpen: boolean; onClose: () => void; onConfirm: () => Promise<void>; onConfirmAndPrint: () => Promise<void>;
  onPaymentsChange: (payments: PaymentInput[] | undefined) => void;
  isProcessing: boolean; customer: POSCustomerDraft | null; items: POSSalePayload['items'];
  discount: number; exchangeFee: number; notes: string;
  saleResult: { sale_id: string; subtotal: number; total_amount: number } | null;
}

export const CheckoutConfirmModal = ({ isOpen, onClose, onConfirm, onConfirmAndPrint, onPaymentsChange, isProcessing, customer, items, discount, exchangeFee, notes }: CheckoutConfirmModalProps) => {
  const { data: inventory } = useInventoryBalances(); const { profile, can } = useAuth();
  const wallets = usePaymentWallets(isOpen); const paperWidth = useReceiptPaperWidth();
  const [advanced, setAdvanced] = useState(false); const [entries, setEntries] = useState<PaymentDraft[]>([]);
  const [createdAt] = useState(() => new Date().toISOString());
  const subtotal = items.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);
  const total = subtotal - discount + exchangeFee;
  const validation = validatePayments(entries, total, wallets.data ?? []);
  const invalid = advanced && (Boolean(validation.error) || !wallets.data);
  const changeEntries = (next: PaymentDraft[]) => {
    setEntries(next); onPaymentsChange(validatePayments(next, total, wallets.data ?? []).payments);
  };
  if (!isOpen) return null;
  return <PurchaseDialog title="Confirm Sale" subtitle="Review the payment and receipt before confirming." onClose={onClose} busy={isProcessing} compact>
    <div className="modal-body">
      {can('receipts:print') && <div style={{ marginBottom: '.75rem' }}><ReceiptPrintMethodSelect disabled={isProcessing} /></div>}
      <section className="advanced-payments">
        <button type="button" className="btn btn-ghost" aria-expanded={advanced} disabled={isProcessing} onClick={() => {
          const next = !advanced; setAdvanced(next);
          if (next) changeEntries(total > 0 ? [paymentDraft(wallets.data ?? [], total)] : []);
          else onPaymentsChange(undefined);
        }}>Advanced payments <ChevronDown size={16} style={{ transform: advanced ? 'rotate(180deg)' : undefined }} /></button>
        {advanced && <>{wallets.isPending && <p role="status">Loading payment wallets…</p>}{wallets.error && <p className="payment-error" role="alert">Wallets could not be loaded. <button className="btn btn-secondary" onClick={() => void wallets.refetch()}>Retry</button></p>}
          {wallets.data && <PaymentEntries wallets={wallets.data} total={total} entries={entries} onChange={changeEntries} disabled={isProcessing} />}
        </>}
      </section>
      <ReceiptPreview width={paperWidth} receipt={{
        sale_id: 'PENDING', created_at: createdAt, shop_name: profile?.business_name,
        customer_name: customer?.name || 'Unknown', customer_phone: customer?.phone || '', customer_tier: customer?.tier || 'retail',
        subtotal, discount_amount: discount, exchange_fee: exchangeFee, total_amount: total, notes,
        paid_amount: advanced ? validation.paid : total, due_amount: advanced ? Math.max(0, validation.due) : 0,
        payments: advanced ? validation.payments.map(p => ({ wallet_name: wallets.data?.find(w => w.wallet_id === p.wallet_id)?.name || '', method: wallets.data?.find(w => w.wallet_id === p.wallet_id)?.kind || 'cash', amount: p.amount })) : [{ wallet_name: wallets.data?.find(w => w.type === 'cash')?.name ?? 'Cash Register', method: 'cash', amount: total }],
        items: items.map(item => { const product = inventory?.find(i => i.item_id === item.item_id); return { name: product ? `${product.lpg_brands?.brand_name || product.brand} ${product.size_kg}kg` : 'Unknown', type: item.type, quantity: item.quantity, unit_price: item.unit_price, line_total: item.quantity * item.unit_price }; }),
      }} />
    </div><div className="modal-footer">
      <button className="btn btn-secondary" disabled={isProcessing} onClick={onClose}>Cancel</button>
      <button className="btn btn-secondary" disabled={isProcessing || invalid} onClick={() => void onConfirm()}><CheckCircle2 size={15} />{isProcessing ? 'Processing…' : 'Confirm'}</button>
      {can('receipts:print') && <button className="btn btn-primary" disabled={isProcessing || invalid} onClick={() => void onConfirmAndPrint()}><Printer size={15} />{isProcessing ? 'Processing…' : 'Confirm & Print'}</button>}
    </div>
  </PurchaseDialog>;
};
