import { useInventoryBalances } from '../../hooks/useInventory';
import toast from 'react-hot-toast';
import type { POSSalePayload } from '../../hooks/usePOS';

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
  items, onChangeItems, 
  discount, onChangeDiscount, 
  exchangeFee, onChangeExchangeFee,
  notes, onChangeNotes 
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
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0, gap: 0 }}>
      {/* Items List — only this section scrolls */}
      <div style={{ flex: 1, overflowY: 'auto', minHeight: 0, display: 'flex', flexDirection: 'column', gap: '0.4rem', padding: '0.5rem 0.75rem' }}>
        {items.length === 0 ? (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', height: '100%', color: 'var(--text-muted)', opacity: 0.5 }}>
            <div style={{ fontSize: '2rem', marginBottom: '0.5rem' }}>🛒</div>
            <p style={{ fontSize: '0.82rem', margin: 0 }}>Cart is empty</p>
          </div>
        ) : (
          items.map((item, index) => {
            const invItem = inventoryItems?.find(i => i.item_id === item.item_id);
            const name = invItem ? `${invItem.lpg_brands?.brand_name} ${invItem.size_kg}kg` : 'Unknown';

            return (
              <div key={`${item.item_id}-${item.type}-${index}`} style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '0.5rem 0.6rem', border: '1px solid var(--border-color)', borderRadius: 8,
              }}>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontWeight: 600, fontSize: '0.8rem', color: 'var(--text-main)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{name}</div>
                  <div style={{ fontSize: '0.7rem', color: 'var(--text-muted)', textTransform: 'capitalize' }}>
                    {item.type.replace('_', ' ')} · ${Number(item.unit_price || 0).toFixed(2)}
                  </div>
                </div>

                <div style={{ display: 'flex', alignItems: 'center', gap: '0.25rem', flexShrink: 0 }}>
                  <button className="btn btn-ghost" style={{ padding: '0.15rem 0.4rem', fontSize: '0.8rem', minWidth: 24 }} onClick={() => handleQuantityChange(item.item_id, item.type, item.quantity - 1)}>−</button>
                  <span style={{ minWidth: '1.2rem', textAlign: 'center', fontWeight: 700, fontSize: '0.82rem' }}>{item.quantity}</span>
                  <button className="btn btn-ghost" style={{ padding: '0.15rem 0.4rem', fontSize: '0.8rem', minWidth: 24 }} onClick={() => handleQuantityChange(item.item_id, item.type, item.quantity + 1)}>+</button>
                </div>

                <div style={{ minWidth: '3.5rem', textAlign: 'right', fontWeight: 700, fontSize: '0.88rem', color: 'var(--primary)', flexShrink: 0 }}>
                  ${(item.quantity * Number(item.unit_price || 0)).toFixed(2)}
                </div>
              </div>
            );
          })
        )}
      </div>

      {/* Empties Warning — pinned */}
      {refillsCount !== emptiesCount && (
        <div style={{ margin: '0 0.75rem', padding: '0.5rem 0.7rem', background: 'rgba(239, 68, 68, 0.1)', color: '#fca5a5', border: '1px solid rgba(239, 68, 68, 0.2)', borderRadius: 8, fontSize: '0.72rem', display: 'flex', alignItems: 'center', gap: '0.4rem', flexShrink: 0 }}>
          <span>⚠️</span>
          <div><strong>Mismatch:</strong> {refillsCount} refills, {emptiesCount} empties</div>
        </div>
      )}

      {/* Adjustments — pinned */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem', padding: '0.6rem 0.75rem', borderTop: '1px solid var(--border-color)', flexShrink: 0 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <label className="input-label" style={{ margin: 0, fontSize: '0.72rem' }}>Discount ($)</label>
          <input
            type="number"
            className="input-field"
            style={{ width: '90px', textAlign: 'right', padding: '0.35rem 0.5rem', fontSize: '0.8rem' }}
            value={discount}
            onChange={(e) => onChangeDiscount(Math.max(0, Number(e.target.value)))}
            min="0" step="0.01"
          />
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <label className="input-label" style={{ margin: 0, fontSize: '0.72rem' }}>Exchange Fee ($)</label>
          <input
            type="number"
            className="input-field"
            style={{ width: '90px', textAlign: 'right', padding: '0.35rem 0.5rem', fontSize: '0.8rem' }}
            value={exchangeFee}
            onChange={(e) => onChangeExchangeFee(Math.max(0, Number(e.target.value)))}
            min="0" step="0.01"
          />
        </div>
        <div className="input-group" style={{ marginBottom: 0 }}>
          <label className="input-label" style={{ fontSize: '0.72rem' }}>Notes</label>
          <textarea
            className="input-field"
            rows={2}
            value={notes}
            onChange={(e) => onChangeNotes(e.target.value)}
            placeholder="Optional notes..."
            style={{ resize: 'none', fontSize: '0.78rem', padding: '0.35rem 0.5rem' }}
          />
        </div>
      </div>

      {/* Totals — pinned */}
      <div style={{ padding: '0.5rem 0.75rem', borderTop: '1px solid var(--border-color)', flexShrink: 0 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.4rem', color: 'var(--text-muted)', fontSize: '0.8rem' }}>
          <span>Subtotal</span>
          <span>${subtotal.toFixed(2)}</span>
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '1.35rem', fontWeight: 800, color: 'var(--text-main)', borderTop: '1px solid var(--border-color)', paddingTop: '0.4rem' }}>
          <span>Total</span>
          <span style={{ color: 'var(--primary)' }}>${total.toFixed(2)}</span>
        </div>
      </div>
    </div>
  );
};
