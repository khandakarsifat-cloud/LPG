import { useInventoryBalances } from '../../hooks/useInventory';
import { usePriceBooks } from '../../hooks/usePOS';
import type { POSSalePayload } from '../../hooks/usePOS';
import type { MouthSize } from '../../types/inventory';

interface POSItemsGridProps {
  onAddItem: (item: POSSalePayload['items'][0]) => void;
  tier: string;
  mouthSize: MouthSize;
}

export const POSItemsGrid = ({ onAddItem, tier, mouthSize }: POSItemsGridProps) => {
  const { data: allItems, isLoading: loadingItems } = useInventoryBalances();
  const { data: priceBooks, isLoading: loadingPrices } = usePriceBooks();

  // Filter items to the selected mouth size (items without mouth_size are shown regardless)
  const items = allItems?.filter(i => !i.mouth_size || i.mouth_size === mouthSize);

  if (loadingItems || loadingPrices) {
    return <div>Loading inventory...</div>;
  }

  const getPrice = (itemId: string, type: 'refill' | 'package') => {
    // Find price for this item + tier + type
    const pb = priceBooks?.find(p => p.item_id === itemId && p.customer_tier === tier && p.price_type === type);
    // Fallback to retail if wholesale not found, or 0 if nothing found
    if (!pb && tier !== 'retail') {
      const retailPb = priceBooks?.find(p => p.item_id === itemId && p.customer_tier === 'retail' && p.price_type === type);
      return Number(retailPb?.price || 0);
    }
    return Number(pb?.price || 0);
  };

  if (!items || items.length === 0) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', height: '100%', color: 'var(--text-muted)', opacity: 0.5, gap: '0.5rem' }}>
        <div style={{ fontSize: '2.5rem' }}>🛢️</div>
        <p style={{ fontSize: '0.85rem' }}>No items with {mouthSize} mouth size</p>
      </div>
    );
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: '1.5rem' }}>
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
              position: 'relative',
              overflow: 'hidden',
              padding: 0,
              transition: 'transform 0.2s, box-shadow 0.2s',
            }}
            onMouseEnter={e => {
              (e.currentTarget as HTMLDivElement).style.transform = 'translateY(-2px)';
              (e.currentTarget as HTMLDivElement).style.boxShadow = '0 8px 32px rgba(0,0,0,0.35)';
            }}
            onMouseLeave={e => {
              (e.currentTarget as HTMLDivElement).style.transform = 'translateY(0)';
              (e.currentTarget as HTMLDivElement).style.boxShadow = '';
            }}
          >
            {/* Card Header */}
            <div style={{ padding: '0.875rem 1rem 0.75rem', display: 'flex', alignItems: 'flex-start', gap: '0.625rem' }}>
              {/* Icon */}
              <div style={{
                width: 32, height: 32, borderRadius: 8,
                background: inStock ? 'rgba(var(--accent-rgb, 99,179,237), 0.15)' : 'rgba(239,68,68,0.12)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: '1rem', flexShrink: 0,
              }}>
                🛢️
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
                  <h3 style={{ margin: 0, fontSize: '0.9rem', fontWeight: 700, color: 'var(--text-main)', lineHeight: 1.3, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    {item.lpg_brands?.brand_name} {item.size_kg}kg
                  </h3>
                  {item.mouth_size && (
                    <span style={{
                      fontSize: '0.6rem', fontWeight: 700, padding: '0.1rem 0.35rem', borderRadius: 10,
                      background: 'rgba(139,92,246,0.15)', color: '#a78bfa', flexShrink: 0,
                      border: '1px solid rgba(139,92,246,0.25)',
                    }}>
                      {item.mouth_size}
                    </span>
                  )}
                </div>
                {/* Stock badges */}
                <div style={{ display: 'flex', gap: '0.5rem', marginTop: '0.5rem', flexWrap: 'wrap' }}>
                  <span style={{
                    fontSize: '0.66rem', fontWeight: 600, padding: '0.15rem 0.45rem', borderRadius: 20,
                    background: inStock ? 'rgba(var(--accent-rgb, 99,179,237), 0.15)' : 'rgba(239,68,68,0.15)',
                    color: inStock ? 'var(--accent)' : 'var(--danger)',
                  }}>
                    ● {item.filled_quantity} filled
                  </span>
                  <span style={{
                    fontSize: '0.66rem', fontWeight: 600, padding: '0.15rem 0.45rem', borderRadius: 20,
                    background: 'rgba(255,255,255,0.06)',
                    color: 'var(--text-muted)',
                  }}>
                    ○ {item.empty_quantity} empty
                  </span>
                </div>
              </div>
            </div>

            {/* Divider */}
            <div style={{ height: 1, background: 'var(--border-color)', margin: '0 1.25rem', opacity: 0.5 }} />

            {/* Action Buttons */}
            <div style={{ padding: '0.6rem 1rem 0.875rem', display: 'flex', flexDirection: 'column', gap: '0.35rem' }}>
              {/* Refill */}
              <button
                className="btn"
                onClick={() => onAddItem({ item_id: item.item_id, type: 'refill', quantity: 1, unit_price: refillPrice })}
                style={{
                  display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '0.55rem 0.8rem', borderRadius: 8,
                  fontWeight: 600, fontSize: '0.82rem',
                  background: 'transparent',
                  border: '1.5px solid var(--border-color)',
                  color: 'var(--text-main)',
                  cursor: 'pointer',
                  transition: 'border-color 0.2s, background 0.2s',
                }}
                onMouseEnter={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = 'var(--accent)'; (e.currentTarget as HTMLButtonElement).style.background = 'rgba(var(--accent-rgb,99,179,237),0.08)'; }}
                onMouseLeave={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = 'var(--border-color)'; (e.currentTarget as HTMLButtonElement).style.background = 'transparent'; }}
              >
                <span style={{ display: 'flex', alignItems: 'center', gap: '0.35rem' }}>
                  <span style={{ fontSize: '0.8rem' }}>🔄</span> Refill
                </span>
                <span style={{ fontSize: '0.78rem', color: 'var(--text-muted)' }}>
                  ${refillPrice.toFixed(2)}
                </span>
              </button>

              {/* New Package — outlined secondary */}
              <button
                className="btn"
                onClick={() => onAddItem({ item_id: item.item_id, type: 'package', quantity: 1, unit_price: packagePrice })}
                style={{
                  display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '0.55rem 0.8rem', borderRadius: 8,
                  fontWeight: 600, fontSize: '0.82rem',
                  background: 'transparent',
                  border: '1.5px solid var(--border-color)',
                  color: 'var(--text-main)',
                  cursor: 'pointer',
                  transition: 'border-color 0.2s, background 0.2s',
                }}
                onMouseEnter={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = 'var(--accent)'; (e.currentTarget as HTMLButtonElement).style.background = 'rgba(var(--accent-rgb,99,179,237),0.08)'; }}
                onMouseLeave={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = 'var(--border-color)'; (e.currentTarget as HTMLButtonElement).style.background = 'transparent'; }}
              >
                <span style={{ display: 'flex', alignItems: 'center', gap: '0.35rem' }}>
                  <span style={{ fontSize: '0.8rem' }}>📦</span> New Package
                </span>
                <span style={{ fontSize: '0.78rem', color: 'var(--text-muted)' }}>
                  ${packagePrice.toFixed(2)}
                </span>
              </button>

              {/* Return Empty — muted ghost */}
              <button
                className="btn"
                onClick={() => onAddItem({ item_id: item.item_id, type: 'empty_return', quantity: 1, unit_price: 0 })}
                style={{
                  display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '0.4rem 0.8rem', borderRadius: 8,
                  fontWeight: 500, fontSize: '0.75rem',
                  background: 'transparent',
                  border: '1px dashed rgba(255,255,255,0.15)',
                  color: 'var(--text-muted)',
                  cursor: 'pointer',
                  transition: 'border-color 0.2s, color 0.2s',
                }}
                onMouseEnter={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = 'rgba(255,255,255,0.35)'; (e.currentTarget as HTMLButtonElement).style.color = 'var(--text-main)'; }}
                onMouseLeave={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = 'rgba(255,255,255,0.15)'; (e.currentTarget as HTMLButtonElement).style.color = 'var(--text-muted)'; }}
              >
                <span style={{ display: 'flex', alignItems: 'center', gap: '0.3rem' }}>
                  <span style={{ fontSize: '0.75rem' }}>↩️</span> Return Empty
                </span>
                <span style={{ fontSize: '0.72rem' }}>$0.00</span>
              </button>
            </div>
          </div>
        );
      })}
    </div>
  );
};
