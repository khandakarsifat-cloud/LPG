import { Box, Package, RefreshCw, RotateCcw } from 'lucide-react';
import { useInventoryBalances } from '../../hooks/useInventory';
import { usePriceBooks } from '../../hooks/usePOS';
import type { POSSalePayload } from '../../hooks/usePOS';
import type { MouthSize } from '../../types/inventory';
import { formatBDNumber } from '../../lib/formatBDT';

interface POSItemsGridProps {
  onAddItem: (item: POSSalePayload['items'][0]) => void;
  tier: string;
  mouthSize: MouthSize;
}

export const POSItemsGrid = ({ onAddItem, tier, mouthSize }: POSItemsGridProps) => {
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
    const pb = priceBooks?.find(p => p.item_id === itemId && p.customer_tier === tier && p.price_type === type);
    if (!pb && tier !== 'retail') {
      const retailPb = priceBooks?.find(p => p.item_id === itemId && p.customer_tier === 'retail' && p.price_type === type);
      return Number(retailPb?.price || 0);
    }
    return Number(pb?.price || 0);
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
              <button
                className="btn btn-secondary"
                onClick={() => onAddItem({ item_id: item.item_id, type: 'refill', quantity: 1, unit_price: refillPrice })}
                style={{ justifyContent: 'space-between' }}
              >
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.35rem' }}>
                  <RefreshCw size={14} /> Refill
                </span>
                <span>Tk {formatBDNumber(refillPrice)}</span>
              </button>

              <button
                className="btn btn-secondary"
                onClick={() => onAddItem({ item_id: item.item_id, type: 'package', quantity: 1, unit_price: packagePrice })}
                style={{ justifyContent: 'space-between' }}
              >
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.35rem' }}>
                  <Box size={14} /> New Package
                </span>
                <span>Tk {formatBDNumber(packagePrice)}</span>
              </button>

              <button
                className="btn btn-ghost"
                onClick={() => onAddItem({ item_id: item.item_id, type: 'empty_return', quantity: 1, unit_price: 0 })}
                style={{ justifyContent: 'space-between', borderStyle: 'dashed' }}
              >
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.35rem' }}>
                  <RotateCcw size={14} /> Return Empty
                </span>
                <span>Tk 0.00</span>
              </button>
            </div>
          </div>
        );
      })}
    </div>
  );
};
