import { PurchaseNumber } from '../purchases/PurchaseControls';
import { AlertTriangle, Minus, Plus, ShoppingCart } from 'lucide-react';
import toast from 'react-hot-toast';
import type { POSSalePayload } from '../../hooks/usePOS';
import { useInventoryBalances } from '../../hooks/useInventory';
import { formatBDNumber } from '../../lib/formatBDT';

interface POSCartProps {
  items: POSSalePayload['items'];
  onChangeItems: (items: POSSalePayload['items']) => void;
  discount: number;
  onChangeDiscount: (val: number) => void;
  exchangeFee: number;
  onChangeExchangeFee: (val: number) => void;
  notes: string;
  onChangeNotes: (val: string) => void;
}

export const POSCart = ({
  items,
  onChangeItems,
  discount,
  onChangeDiscount,
  exchangeFee,
  onChangeExchangeFee,
  notes,
  onChangeNotes,
}: POSCartProps) => {
  const { data: inventoryItems } = useInventoryBalances();

  const subtotal = items.reduce((acc, curr) => acc + (curr.quantity * Number(curr.unit_price || 0)), 0);
  const total = subtotal - Number(discount || 0) + Number(exchangeFee || 0);

  const handleRemove = (item_id: string, type: string) => {
    onChangeItems(items.filter(i => !(i.item_id === item_id && i.type === type)));
  };

  const handleQuantityChange = (item_id: string, type: string, newQty: number) => {
    if (newQty < 1) {
      handleRemove(item_id, type);
      return;
    }

    if (type === 'refill' || type === 'package') {
      const invItem = inventoryItems?.find(i => i.item_id === item_id);
      const maxStock = invItem?.filled_quantity || 0;

      const currentOtherQty = items
        .filter(i => i.item_id === item_id && (i.type === 'refill' || i.type === 'package') && i.type !== type)
        .reduce((acc, curr) => acc + curr.quantity, 0);

      if (newQty + currentOtherQty > maxStock) {
        toast.error(`Cannot exceed available stock (${maxStock}).`);
        return;
      }
    }

    onChangeItems(items.map(i => i.item_id === item_id && i.type === type ? { ...i, quantity: newQty } : i));
  };

  const refillsCount = items.filter(i => i.type === 'refill').reduce((acc, curr) => acc + curr.quantity, 0);
  const emptiesCount = items.filter(i => i.type === 'empty_return').reduce((acc, curr) => acc + curr.quantity, 0);

  return (
    <div className="pos-cart">
      <div className="pos-cart-lines">
        {items.length === 0 ? (
          <div className="empty-state pos-cart-empty">
            <ShoppingCart size={28} />
            <p style={{ margin: 0 }}>Cart is empty</p>
          </div>
        ) : (
          items.map((item, index) => {
            const invItem = inventoryItems?.find(i => i.item_id === item.item_id);
            const name = invItem ? `${invItem.lpg_brands?.brand_name} ${invItem.size_kg}kg` : 'Unknown';

            return (
              <div className="pos-cart-line" key={`${item.item_id}-${item.type}-${index}`} style={{
                display: 'grid',
                gridTemplateColumns: 'minmax(0, 1fr) auto auto',
                gap: '0.5rem',
                alignItems: 'center',
                padding: '0.5rem 0.6rem',
                border: '1px solid var(--border-color)',
                borderRadius: 'var(--radius-md)',
                background: 'var(--surface)',
              }}>
                <div style={{ minWidth: 0 }}>
                  <div style={{ fontWeight: 700, fontSize: '0.8rem', color: 'var(--text-main)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{name}</div>
                  <div style={{ fontSize: '0.7rem', color: 'var(--text-muted)', textTransform: 'capitalize' }}>
                    {item.type.replace('_', ' ')} - Tk {formatBDNumber(Number(item.unit_price || 0))}
                  </div>
                </div>

                <div style={{ display: 'flex', alignItems: 'center', gap: '0.25rem' }}>
                  <button className="btn btn-ghost" style={{ width: 28, height: 28, minHeight: 28, padding: 0 }} onClick={() => handleQuantityChange(item.item_id, item.type, item.quantity - 1)} aria-label="Decrease quantity">
                    <Minus size={13} />
                  </button>
                  <span style={{ minWidth: '1.3rem', textAlign: 'center', fontWeight: 800, fontSize: '0.82rem' }}>{item.quantity}</span>
                  <button className="btn btn-ghost" style={{ width: 28, height: 28, minHeight: 28, padding: 0 }} onClick={() => handleQuantityChange(item.item_id, item.type, item.quantity + 1)} aria-label="Increase quantity">
                    <Plus size={13} />
                  </button>
                </div>

                <div style={{ minWidth: '4.5rem', textAlign: 'right', fontWeight: 800, fontSize: '0.88rem', color: 'var(--primary)' }}>
                  Tk {formatBDNumber(item.quantity * Number(item.unit_price || 0))}
                </div>
              </div>
            );
          })
        )}
      </div>

      {refillsCount !== emptiesCount && (
        <div style={{ margin: '0 0.75rem', padding: '0.5rem 0.7rem', background: 'var(--danger-weak)', color: 'var(--danger)', border: '1px solid #fda29b', borderRadius: 'var(--radius-md)', fontSize: '0.72rem', display: 'flex', alignItems: 'center', gap: '0.4rem', flexShrink: 0 }}>
          <AlertTriangle size={14} />
          <div><strong>Mismatch:</strong> {refillsCount} refills, {emptiesCount} empties</div>
        </div>
      )}

      <div className="pos-cart-fields">
        <PurchaseNumber label="Discount (Tk)" money value={discount} onChange={value => onChangeDiscount(value ?? 0)} />
        <PurchaseNumber label="Exchange Fee (Tk)" money value={exchangeFee} onChange={value => onChangeExchangeFee(value ?? 0)} />
        <label className="pos-cart-field pos-cart-notes">
          <span>Notes</span>
          <textarea
            className="input-field"
            rows={1}
            value={notes}
            onChange={(e) => onChangeNotes(e.target.value)}
            placeholder="Optional notes..."
            style={{ resize: 'vertical' }}
          />
        </label>
      </div>

      <div style={{ padding: '0.5rem 0.75rem', borderTop: '1px solid var(--border-color)', flexShrink: 0 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.4rem', color: 'var(--text-muted)', fontSize: '0.8rem' }}>
          <span>Subtotal</span>
          <span>Tk {formatBDNumber(subtotal)}</span>
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '1.125rem', fontWeight: 800, color: 'var(--text-main)', borderTop: '1px solid var(--border-color)', paddingTop: '0.4rem' }}>
          <span>Total</span>
          <span style={{ color: 'var(--primary)' }}>Tk {formatBDNumber(total)}</span>
        </div>
      </div>
    </div>
  );
};
