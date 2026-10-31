import { useStoveProducts } from '../../hooks/useAccounting';
import type { BusinessCategory } from '../../types/accounting';
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
import { ReceivedBottles } from './ReceivedBottles';
import { validateBottles } from '../../lib/bottles';
import type { BottleInput, BottleObligation } from '../../types/bottles';
import '../purchases/purchases.css';
import { useLPGBrands } from '../../hooks/useBrands';
import { groupInventoryByBrand, orderSaleLines } from '../../lib/inventoryGroups';

interface CheckoutConfirmModalProps {
  category?: BusinessCategory; isOpen: boolean; onClose: () => void; onConfirm: () => Promise<void>; onConfirmAndPrint: () => Promise<void>;
  onPaymentsChange: (payments: PaymentInput[] | undefined) => void;
  onBottlesChange: (bottles: BottleInput | undefined) => void;
  isProcessing: boolean; customer: POSCustomerDraft | null; items: POSSalePayload['items'];
  discount: number; exchangeFee: number; notes: string;
  saleResult: { sale_id: string; subtotal: number; total_amount: number } | null;
}

export const CheckoutConfirmModal = ({ category = 'lpg', isOpen, onClose, onConfirm, onConfirmAndPrint, onPaymentsChange, onBottlesChange, isProcessing, customer, items, discount, exchangeFee, notes }: CheckoutConfirmModalProps) => {
  const { data: inventory } = useInventoryBalances(); const { profile, can } = useAuth();
  const wallets = usePaymentWallets(isOpen); const paperWidth = useReceiptPaperWidth();
  const [advanced, setAdvanced] = useState(false); const [entries, setEntries] = useState<PaymentDraft[]>([]);
  const [showBottles, setShowBottles] = useState(false);
  const brands = useLPGBrands();
  const stoves = useStoveProducts(category === 'stove');
  const orderedItems = orderSaleLines(items, groupInventoryByBrand(inventory ?? [], brands.data ?? []).flatMap(group => group.items.map(item => item.item_id)));

  const products = (inventory ?? []).map(i => ({ item_id: i.item_id, name: `${i.lpg_brands?.brand_name ?? 'Product unavailable'} ${i.size_kg}kg ${i.mouth_size ?? ''}`.trim(), size_kg: Number(i.size_kg), mouth_size: i.mouth_size ?? null }));
  const obligations: BottleObligation[] = items.filter(i => i.type === 'empty_return').map(i => ({ ...(products.find(p => p.item_id === i.item_id) ?? { item_id: i.item_id, name: 'Loading product…', size_kg: 0, mouth_size: null }), expected: i.quantity, difference: i.quantity, received: 0 }));
  const [bottleInput, setBottleInput] = useState<BottleInput>(() => ({ lines: items.filter(i => i.type === 'empty_return').map(i => ({ received_item_id: i.item_id, quantity: i.quantity })), note: '' }));
  const bottleValidation = validateBottles(obligations, products, bottleInput.lines.filter(l => l.quantity !== 0));
  const changeBottles = (next: BottleInput) => { setBottleInput(next); onBottlesChange({ ...next, lines: next.lines.filter(l => l.quantity !== 0) }); };
  const [createdAt] = useState(() => new Date().toISOString());
  const subtotal = items.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);
  const total = subtotal - discount + exchangeFee;
  const validation = validatePayments(entries, total, wallets.data ?? []);
  const invalid = (advanced && (Boolean(validation.error) || !wallets.data)) || Boolean(bottleValidation.error);
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
      {obligations.length > 0 && <section className="advanced-payments">
        <button type="button" className="btn btn-ghost bottle-checkout-toggle" aria-expanded={showBottles} aria-controls="checkout-bottle-controls" disabled={isProcessing} onClick={() => setShowBottles(previous => !previous)}>
          <span>Received bottles <small>{bottleValidation.received} of {obligations.reduce((sum, line) => sum + line.expected, 0)} received · {Math.max(0, obligations.reduce((sum, line) => sum + line.expected, 0) - bottleValidation.received)} outstanding</small></span>
          <ChevronDown size={16} style={{ transform: showBottles ? 'rotate(180deg)' : undefined }} />
        </button>
        <div id="checkout-bottle-controls" hidden={!showBottles}><ReceivedBottles obligations={obligations} products={products} catalog={inventory ?? []} brands={brands.data ?? []} value={bottleInput} onChange={changeBottles} disabled={isProcessing} /></div>
        {!showBottles && bottleValidation.error && <p className="payment-error" role="alert">{bottleValidation.error} Expand received bottles to review.</p>}
      </section>}
      <ReceiptPreview width={paperWidth} receipt={{
        business_category: category, sale_id: 'PENDING', created_at: createdAt, shop_name: profile?.business_name,
        customer_name: customer?.name || 'Unknown', customer_phone: customer?.phone || '', customer_tier: customer?.tier || 'retail',
        subtotal, discount_amount: discount, exchange_fee: exchangeFee, total_amount: total, notes,
        paid_amount: advanced ? validation.paid : total, due_amount: advanced ? Math.max(0, validation.due) : 0, unattributed_paid: 0,
        payments: advanced ? validation.payments.map(p => ({ wallet_name: wallets.data?.find(w => w.wallet_id === p.wallet_id)?.name || '', method: wallets.data?.find(w => w.wallet_id === p.wallet_id)?.kind || 'cash', amount: p.amount })) : [{ wallet_name: wallets.data?.find(w => w.type === 'cash')?.name ?? 'Cash Register', method: 'cash', amount: total }],
        bottles: { expected: obligations.reduce((sum,o) => sum + o.expected,0), received: bottleValidation.received, outstanding: Math.max(0, obligations.reduce((sum,o) => sum + o.expected,0) - bottleValidation.received),
          actual: bottleInput.lines.filter(l => l.quantity > 0).map(l => ({ phase: 'checkout' as const, item_id: l.received_item_id, name: products.find(p => p.item_id === l.received_item_id)?.name ?? 'Unknown', quantity: l.quantity })),
          obligations: obligations.map(o => ({ name: o.name, expected: o.expected })) },
        items: orderedItems.map(item => { const product = inventory?.find(i => i.item_id === item.item_id); return { item_id: item.item_id, name: category === 'stove' ? stoves.data?.find(p => p.item_id === item.item_id)?.product_name ?? 'Loading product…' : product ? `${product.lpg_brands?.brand_name ?? 'Product unavailable'} ${product.size_kg}kg${product.mouth_size ? ` ${product.mouth_size}` : ''}` : 'Unknown', type: item.type, quantity: item.quantity, unit_price: item.unit_price, line_total: item.quantity * item.unit_price }; }),
      }} />
    </div><div className="modal-footer">
      <button className="btn btn-secondary" disabled={isProcessing} onClick={onClose}>Cancel</button>
      <button className="btn btn-secondary" disabled={isProcessing || invalid} onClick={() => void onConfirm()}><CheckCircle2 size={15} />{isProcessing ? 'Processing…' : 'Confirm'}</button>
      {can('receipts:print') && <button className="btn btn-primary" disabled={isProcessing || invalid} onClick={() => void onConfirmAndPrint()}><Printer size={15} />{isProcessing ? 'Processing…' : 'Confirm & Print'}</button>}
    </div>
  </PurchaseDialog>;
};
