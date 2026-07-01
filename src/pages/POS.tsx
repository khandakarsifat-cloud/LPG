import { useState, useCallback } from 'react';
import toast from 'react-hot-toast';
import { AlertCircle } from 'lucide-react';
import { POSItemsGrid } from '../components/pos/POSItemsGrid';
import { POSCart } from '../components/pos/POSCart';
import { CustomerSelection } from '../components/pos/CustomerSelection';
import { CheckoutConfirmModal } from '../components/pos/CheckoutConfirmModal';
import type { POSCustomerDraft } from '../components/pos/CustomerSelection';
import { useCreatePOSSale } from '../hooks/usePOS';
import { useInventoryBalances } from '../hooks/useInventory';
import type { POSSalePayload, POSSaleResult } from '../hooks/usePOS';
import type { MouthSize } from '../types/inventory';
import { MOUTH_SIZE_OPTIONS } from '../types/inventory';
import { printReceipt, type ReceiptData } from '../lib/receiptPdf';
import { useAuth } from '../contexts/AuthContext';
import { BD_MOBILE_PHONE_ERROR, validateBDMobilePhone } from '../lib/bdPhone';

const resetForm = (
  setItems: React.Dispatch<React.SetStateAction<POSSalePayload['items']>>,
  setCustomer: React.Dispatch<React.SetStateAction<POSCustomerDraft | null>>,
  setDiscount: React.Dispatch<React.SetStateAction<number>>,
  setExchangeFee: React.Dispatch<React.SetStateAction<number>>,
  setNotes: React.Dispatch<React.SetStateAction<string>>,
) => {
  setItems([]);
  setCustomer(null);
  setDiscount(0);
  setExchangeFee(0);
  setNotes('');
};

export const POSPage = () => {
  const [items, setItems]               = useState<POSSalePayload['items']>([]);
  const [customer, setCustomer]         = useState<POSCustomerDraft | null>(null);
  const [discount, setDiscount]         = useState(0);
  const [exchangeFee, setExchangeFee]   = useState(0);
  const [notes, setNotes]               = useState('');
  const [mouthSize, setMouthSize]       = useState<MouthSize>('22mm');
  const [modalOpen, setModalOpen]       = useState(false);
  const [isProcessing, setIsProcessing] = useState(false);
  // pendingPrint reserved for future use
  const [saleResult, setSaleResult]     = useState<POSSaleResult | null>(null);

  const { data: inventoryItems } = useInventoryBalances();
  const { mutateAsync: createSale } = useCreatePOSSale();
  const { profile } = useAuth();

  const hasPhone        = Boolean(customer?.phone?.trim());
  const customerPhone   = customer?.phone?.trim() || '';
  const hasValidPhone   = hasPhone && validateBDMobilePhone(customerPhone);
  const refillCount     = items.filter(i => i.type === 'refill').reduce((a, i) => a + i.quantity, 0);
  const emptyCount      = items.filter(i => i.type === 'empty_return').reduce((a, i) => a + i.quantity, 0);
  const parityOk        = refillCount === emptyCount;
  const canCheckout     = items.length > 0 && hasValidPhone && parityOk;

  const getCheckoutBlockReason = () => {
    if (items.length === 0)  return 'Cart is empty';
    if (!hasPhone)           return 'Customer phone number is required';
    if (!hasValidPhone)      return BD_MOBILE_PHONE_ERROR;
    if (!parityOk)           return `Refills (${refillCount}) must equal empty returns (${emptyCount})`;
    return null;
  };

  // Opens the confirmation modal
  const handleCheckoutClick = () => {
    const reason = getCheckoutBlockReason();
    if (reason) {
      toast.error(reason);
      return;
    }
    setModalOpen(true);
  };

  // Executes the sale against Supabase
  const executeSale = useCallback(async () => {
    if (!customer || !customerPhone) {
      throw new Error('Customer phone number is required');
    }

    const payload: POSSalePayload = {
      customerPhone,
      customerName:      customer.name || undefined,
      customerShopName:  customer.shop_name || undefined,
      customerAddress:   customer.address || undefined,
      customerTier:      customer.tier || 'retail',
      discountAmount:    discount,
      exchangeFee:       exchangeFee,
      notes:             notes || undefined,
      items,
    };
    const result = await createSale(payload);
    return result;
  }, [customer, customerPhone, discount, exchangeFee, notes, items, createSale]);

  const buildReceiptData = (result: POSSaleResult): ReceiptData => ({
    sale_id:        result.sale_id,
    created_at:     new Date().toISOString(),
    shop_name:      profile?.business_name || 'Gas Dealership',
    customer_name:  customer?.name || result.customer_name || 'Unknown',
    customer_phone: customer?.phone || result.customer_phone,
    customer_tier:  customer?.tier || 'retail',
    items: items.map(item => {
      const inv = inventoryItems?.find(i => i.item_id === item.item_id);
      return {
        name:       inv ? `${inv.lpg_brands?.brand_name ?? inv.brand} ${inv.size_kg}kg` : 'Unknown',
        type:       item.type,
        quantity:   item.quantity,
        unit_price: Number(item.unit_price),
        line_total: item.quantity * Number(item.unit_price),
      };
    }),
    subtotal:        result.subtotal,
    discount_amount: discount,
    exchange_fee:    exchangeFee,
    total_amount:    result.total_amount,
    notes:           notes || undefined,
  });

  const handleConfirm = async () => {
    setIsProcessing(true);
    try {
      const result = await executeSale();
      setSaleResult(result);
      toast.success('Sale completed successfully! ✅');
      setModalOpen(false);
      resetForm(setItems, setCustomer, setDiscount, setExchangeFee, setNotes);
    } catch (err: unknown) {
      toast.error('Failed to complete sale: ' + (err instanceof Error ? err.message : 'Unknown error'));
    } finally {
      setIsProcessing(false);
    }
  };

  const handleConfirmAndPrint = async () => {
    setIsProcessing(true);
    try {
      const result = await executeSale();
      setSaleResult(result);
      toast.success('Sale completed! Opening receipt… 🖨️');
      setModalOpen(false);
      resetForm(setItems, setCustomer, setDiscount, setExchangeFee, setNotes);
      // Build receipt and print
      const receiptData = buildReceiptData(result);
      setTimeout(() => printReceipt(receiptData), 300);
    } catch (err: unknown) {
      toast.error('Failed to complete sale: ' + (err instanceof Error ? err.message : 'Unknown error'));
    } finally {
      setIsProcessing(false);
    }
  };

  const blockReason = getCheckoutBlockReason();

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0, overflow: 'hidden' }}>

      {/* 2-column layout */}
      <div className="pos-workspace" style={{ display: 'flex', gap: 'var(--space-md)', flex: 1, minHeight: 0 }}>

        {/* LEFT: Products Grid */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 'var(--space-xs)', minHeight: 0, minWidth: 0 }}>
          {/* Title + Mouth Size toggle row */}
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', flexShrink: 0, flexWrap: 'wrap' }}>
            <h1 style={{ margin: 0, fontSize: '1.25rem', fontWeight: 700 }}>🧾 Point of Sale</h1>
            <span style={{ fontSize: '0.75rem', fontWeight: 700, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>Products</span>

            {/* Mouth Size Pill Toggle */}
            <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
              <span style={{ fontSize: '0.7rem', fontWeight: 600, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>Mouth Size</span>
              <div style={{ display: 'flex', background: 'var(--bg-elevated)', borderRadius: 8, padding: '0.2rem', gap: '0.15rem', border: '1px solid var(--border-color)' }}>
                {MOUTH_SIZE_OPTIONS.map(size => (
                  <button
                    key={size}
                    onClick={() => setMouthSize(size)}
                    style={{
                      padding: '0.3rem 0.75rem',
                      borderRadius: 6,
                      border: 'none',
                      cursor: 'pointer',
                      fontWeight: 700,
                      fontSize: '0.78rem',
                      transition: 'all 0.15s',
                      background: mouthSize === size ? 'var(--primary)' : 'transparent',
                      color: mouthSize === size ? 'white' : 'var(--text-muted)',
                      boxShadow: mouthSize === size ? '0 2px 8px rgba(59,130,246,0.4)' : 'none',
                    }}
                  >
                    {size}
                  </button>
                ))}
              </div>
            </div>
          </div>

          <div style={{ flex: 1, overflowY: 'auto', minHeight: 0, paddingRight: '0.25rem' }}>
            <POSItemsGrid
              onAddItem={(item) => {
                if (item.type === 'refill' || item.type === 'package') {
                  const invItem = inventoryItems?.find(i => i.item_id === item.item_id);
                  const maxStock = invItem?.filled_quantity || 0;
                  const currentTotalInCart = items
                    .filter(i => i.item_id === item.item_id && (i.type === 'refill' || i.type === 'package'))
                    .reduce((acc, curr) => acc + curr.quantity, 0);

                  if (currentTotalInCart + item.quantity > maxStock) {
                    toast.error(`Cannot add more. Only ${maxStock} filled cylinders in stock.`);
                    return;
                  }
                }

                setItems(prev => {
                  const existing = prev.find(i => i.item_id === item.item_id && i.type === item.type);
                  if (existing) {
                    return prev.map(i => i === existing ? { ...i, quantity: i.quantity + item.quantity } : i);
                  }
                  return [...prev, item];
                });
              }}
              tier={customer?.tier || 'retail'}
              mouthSize={mouthSize}
            />
          </div>
        </div>

        {/* RIGHT: Customer + Cart stacked */}
        <div className="pos-side-panel" style={{ width: 'clamp(16.5rem, 22vw, 18.75rem)', flexShrink: 0, display: 'flex', flexDirection: 'column', gap: 'var(--space-xs)', minHeight: 0 }}>

          {/* Customer Details */}
          <div className="card" style={{
            flexShrink: 0,
            background: 'var(--bg-secondary)', borderRadius: 'var(--radius-lg)',
            padding: 'var(--space-sm) var(--space-md)',
            border: !hasPhone && items.length > 0 ? '1.5px solid rgba(239,68,68,0.45)' : '1px solid var(--border-color)',
            transition: 'border-color 0.2s',
          }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-xs)', marginBottom: 'var(--space-sm)' }}>
              <span style={{ fontSize: '0.8rem' }}>👤</span>
              <span style={{ fontSize: '0.8rem', fontWeight: 700, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>Customer</span>
              {!hasPhone && (
                <span style={{ marginLeft: 'auto', fontSize: '0.65rem', color: '#fca5a5', fontWeight: 600, display: 'flex', alignItems: 'center', gap: '0.25rem' }}>
                  <AlertCircle size={11} />Required
                </span>
              )}
            </div>
            <CustomerSelection customer={customer} onChange={setCustomer} />
          </div>

          {/* Cart */}
          <div className="card" style={{
            flex: 1, minHeight: 0,
            display: 'flex', flexDirection: 'column',
            background: 'var(--bg-secondary)', borderRadius: 'var(--radius-lg)',
            padding: 0, overflow: 'hidden',
          }}>
            {/* Cart header */}
            <div style={{ padding: 'var(--space-sm) var(--space-md)', borderBottom: '1px solid var(--border-color)', flexShrink: 0 }}>
              <span style={{ fontSize: '0.75rem', fontWeight: 700, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>🛒 Current Sale</span>
            </div>

            {/* POSCart scrollable */}
            <div style={{ flex: 1, minHeight: 0, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
              <POSCart
                items={items}
                onChangeItems={setItems}
                discount={discount}
                onChangeDiscount={setDiscount}
                exchangeFee={exchangeFee}
                onChangeExchangeFee={setExchangeFee}
                notes={notes}
                onChangeNotes={setNotes}
              />
            </div>

            {/* Checkout button */}
            <div style={{ padding: 'var(--space-sm)', borderTop: '1px solid var(--border-color)', flexShrink: 0 }}>
              <button
                className="btn btn-primary"
                style={{
                  width: '100%', padding: 'var(--space-sm)',
                  fontSize: 'var(--font-sm)', fontWeight: 700, borderRadius: 'var(--radius-md)',
                  opacity: canCheckout ? 1 : 0.5,
                  cursor: canCheckout ? 'pointer' : 'not-allowed',
                  transition: 'opacity 0.2s',
                }}
                onClick={handleCheckoutClick}
                disabled={!canCheckout}
                title={blockReason || undefined}
              >
                ✅ Complete Checkout
              </button>

              {/* Inline block reason */}
              {blockReason && items.length > 0 && (
                <div style={{
                  marginTop: '0.45rem',
                  fontSize: '0.68rem',
                  color: '#fca5a5',
                  display: 'flex', alignItems: 'center', gap: '0.3rem',
                  justifyContent: 'center',
                }}>
                  <AlertCircle size={11} />
                  {blockReason}
                </div>
              )}
            </div>
          </div>

        </div>

      </div>

      {/* Checkout Confirmation Modal */}
      <CheckoutConfirmModal
        isOpen={modalOpen}
        onClose={() => { if (!isProcessing) setModalOpen(false); }}
        onConfirm={handleConfirm}
        onConfirmAndPrint={handleConfirmAndPrint}
        isProcessing={isProcessing}
        customer={customer}
        items={items}
        discount={discount}
        exchangeFee={exchangeFee}
        notes={notes}
        saleResult={saleResult}
      />
    </div>
  );
};
