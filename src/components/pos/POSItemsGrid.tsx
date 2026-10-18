import { Box, Minus, Package, Plus, RefreshCw, RotateCcw } from 'lucide-react';
import { useInventoryBalances } from '../../hooks/useInventory';
import { usePriceBooks } from '../../hooks/usePOS';
import type { POSSalePayload } from '../../hooks/usePOS';
import type { MouthSize } from '../../types/inventory';
import { formatBDNumber } from '../../lib/formatBDT';
import { getSellingPrice } from '../../lib/productPricing';

interface ProductOptionRowProps {
  icon: React.ReactNode;
  label: string;
  priceText: string;
  qty: number;
  isGhost?: boolean;
  onIncrease: () => void;
  onDecrease: () => void;
  itemBrand?: string;
  itemSize?: number;
}

const ProductOptionRow = ({
  icon,
  label,
  priceText,
  qty,
  isGhost = false,
  onIncrease,
  onDecrease,
  itemBrand,
  itemSize,
}: ProductOptionRowProps) => {
  return (
    <div
      role="button"
      tabIndex={0}
      onClick={onIncrease}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onIncrease();
        }
      }}
      className={`btn ${isGhost ? 'btn-ghost' : 'btn-secondary'} pos-item-row ${qty > 0 ? 'is-active' : ''}`}
      style={isGhost ? { borderStyle: 'dashed' } : undefined}
      aria-label={`${label} for ${itemBrand || ''} ${itemSize || ''}kg`}
    >
      <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.35rem', minWidth: 0 }}>
        {icon}
        <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{label}</span>
      </span>

      <div style={{ display: 'inline-flex', alignItems: 'center', gap: '0.45rem', flexShrink: 0, marginLeft: 'auto' }}>
        <span
          style={{
            fontSize: '0.8rem',
            fontWeight: 700,
            color: qty > 0 ? 'var(--text-main)' : 'var(--text-muted)',
            whiteSpace: 'nowrap',
          }}
        >
          {priceText}
        </span>

        <div
          className="pos-item-stepper"
          onClick={(e) => e.stopPropagation()}
        >
          <button
            type="button"
            className="pos-item-stepper-btn"
            disabled={qty === 0}
            onClick={(e) => {
              e.stopPropagation();
              if (qty > 0) onDecrease();
            }}
            aria-label={`Decrease ${label} quantity`}
            title={`Decrease ${label}`}
          >
            <Minus size={13} />
          </button>
          <span className={`pos-item-stepper-val ${qty > 0 ? 'has-qty' : ''}`}>
            {qty}
          </span>
          <button
            type="button"
            className="pos-item-stepper-btn"
            onClick={(e) => {
              e.stopPropagation();
              onIncrease();
            }}
            aria-label={`Increase ${label} quantity`}
            title={`Increase ${label}`}
          >
            <Plus size={13} />
          </button>
        </div>
      </div>
    </div>
  );
};

interface POSItemsGridProps {
  cartItems?: POSSalePayload['items'];
  onAddItem: (item: POSSalePayload['items'][0]) => void;
  onDecreaseItem?: (itemId: string, type: 'refill' | 'package' | 'empty_return') => void;
  tier: string;
  mouthSize: MouthSize;
}

export const POSItemsGrid = ({ cartItems = [], onAddItem, onDecreaseItem, tier, mouthSize }: POSItemsGridProps) => {
  const { data: allItems, isLoading: loadingItems } = useInventoryBalances();
  const { data: priceBooks, isLoading: loadingPrices } = usePriceBooks();

  const items = allItems?.filter(i => !i.mouth_size || i.mouth_size === mouthSize);

  if (loadingItems || loadingPrices) {
    return (
      <div className="inv-tiles-grid">
        {Array.from({ length: 8 }).map((_, i) => (
          <div key={i} className="inv-tile inv-tile-skeleton skeleton" />
        ))}
      </div>
    );
  }

  const getPrice = (itemId: string, type: 'refill' | 'package') => {
    return getSellingPrice(priceBooks ?? [], itemId, type, tier);
  };

  if (!items || items.length === 0) {
    return (
      <div className="empty-state" style={{ height: '100%' }}>
        <Package size={30} />
        <p style={{ margin: 0 }}>No items with {mouthSize} mouth size.</p>
      </div>
    );
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(min(100%, 18rem), 1fr))', gap: 'var(--space-md)' }}>
      {items.map(item => {
        const refillPrice = getPrice(item.item_id, 'refill');
        const packagePrice = getPrice(item.item_id, 'package');
        const inStock = item.filled_quantity > 0;
        const refillQty = cartItems.find(i => i.item_id === item.item_id && i.type === 'refill')?.quantity || 0;
        const packageQty = cartItems.find(i => i.item_id === item.item_id && i.type === 'package')?.quantity || 0;
        const emptyQty = cartItems.find(i => i.item_id === item.item_id && i.type === 'empty_return')?.quantity || 0;

        return (
          <div
            key={item.item_id}
            className="card"
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: 0,
              padding: 0,
              overflow: 'hidden',
            }}
          >
            <div style={{ padding: '0.875rem 1rem 0.75rem', display: 'flex', alignItems: 'flex-start', gap: '0.625rem' }}>
              <div className="inv-stat-icon" style={{
                background: inStock ? 'var(--accent-weak)' : 'var(--danger-weak)',
                color: inStock ? 'var(--accent)' : 'var(--danger)',
              }}>
                <Package size={17} />
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
                  <h3 style={{ margin: 0, fontSize: '0.95rem', fontWeight: 800, color: 'var(--text-main)', lineHeight: 1.3, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    {item.lpg_brands?.brand_name} {item.size_kg}kg
                  </h3>
                  {item.mouth_size && (
                    <span className="type-badge" style={{ flexShrink: 0 }}>
                      {item.mouth_size}
                    </span>
                  )}
                </div>
                <div style={{ display: 'flex', gap: '0.5rem', marginTop: '0.5rem', flexWrap: 'wrap' }}>
                  <span className="inv-tile-count inv-tile-count-filled">
                    {item.filled_quantity} filled
                  </span>
                  <span className="inv-tile-count inv-tile-count-empty">
                    {item.empty_quantity} empty
                  </span>
                </div>
              </div>
            </div>

            <div style={{ height: 1, background: 'var(--border-color)', margin: '0 1rem' }} />

            <div style={{ padding: '0.75rem 1rem 1rem', display: 'flex', flexDirection: 'column', gap: '0.4rem' }}>
              <ProductOptionRow
                icon={<RefreshCw size={14} />}
                label="Refill"
                priceText={`Tk ${formatBDNumber(refillPrice)}`}
                qty={refillQty}
                onIncrease={() => onAddItem({ item_id: item.item_id, type: 'refill', quantity: 1, unit_price: refillPrice })}
                onDecrease={() => onDecreaseItem?.(item.item_id, 'refill')}
                itemBrand={item.lpg_brands?.brand_name}
                itemSize={item.size_kg}
              />

              <ProductOptionRow
                icon={<Box size={14} />}
                label="New Package"
                priceText={`Tk ${formatBDNumber(packagePrice)}`}
                qty={packageQty}
                onIncrease={() => onAddItem({ item_id: item.item_id, type: 'package', quantity: 1, unit_price: packagePrice })}
                onDecrease={() => onDecreaseItem?.(item.item_id, 'package')}
                itemBrand={item.lpg_brands?.brand_name}
                itemSize={item.size_kg}
              />

              <ProductOptionRow
                icon={<RotateCcw size={14} />}
                label="Return Empty"
                priceText="Tk 0.00"
                qty={emptyQty}
                isGhost
                onIncrease={() => onAddItem({ item_id: item.item_id, type: 'empty_return', quantity: 1, unit_price: 0 })}
                onDecrease={() => onDecreaseItem?.(item.item_id, 'empty_return')}
                itemBrand={item.lpg_brands?.brand_name}
                itemSize={item.size_kg}
              />
            </div>
          </div>
        );
      })}
    </div>
  );
};

