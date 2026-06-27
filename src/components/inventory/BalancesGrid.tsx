import { useState } from 'react';
import { Package, AlertTriangle, RefreshCw, Droplets, Box, History } from 'lucide-react';
import { useInventoryBalances } from '../../hooks/useInventory';
import { ProductHistoryModal } from './ProductHistoryModal';
import type { ItemWithBrand } from '../../types/inventory';

// ── Status helpers ────────────────────────────────────────────────────────────
const getStockStatus = (filled: number, empty: number) => {
  const total = filled + empty;
  if (total === 0) return 'out';
  if (filled === 0) return 'no-filled';
  if (filled <= 5) return 'low';
  return 'ok';
};

const STATUS_COLOR: Record<string, string> = {
  ok:        'var(--accent)',
  low:       'var(--warning)',
  'no-filled': 'var(--warning)',
  out:       'var(--danger)',
};

const STATUS_LABEL: Record<string, string> = {
  ok:          'In Stock',
  low:         'Low Stock',
  'no-filled': 'No Filled',
  out:         'Out of Stock',
};

// ── Single compact tile ───────────────────────────────────────────────────────
interface TileProps {
  item: ItemWithBrand;
  onClick: () => void;
}

const ProductTile = ({ item, onClick }: TileProps) => {
  const filled  = item.filled_quantity ?? 0;
  const empty   = item.empty_quantity  ?? 0;
  const status  = getStockStatus(filled, empty);
  const color   = STATUS_COLOR[status];
  const brandName = item.lpg_brands?.brand_name ?? item.brand;

  return (
    <button className="inv-tile" onClick={onClick} title={`${brandName} ${item.size_kg}kg — click to view history`}>
      {/* Status dot */}
      <span className="inv-tile-dot" style={{ background: color }} />

      {/* Brand + size */}
      <div className="inv-tile-brand">{brandName}</div>
      <div className="inv-tile-size">{item.size_kg} <span>kg</span></div>

      {/* Stock counts */}
      <div className="inv-tile-counts">
        <div className="inv-tile-count inv-tile-count-filled">
          <Droplets size={11} />
          <span>{filled}</span>
        </div>
        <div className="inv-tile-count inv-tile-count-empty">
          <Box size={11} />
          <span>{empty}</span>
        </div>
      </div>

      {/* Status badge */}
      <div className="inv-tile-status" style={{ color, background: `${color}18` }}>
        {STATUS_LABEL[status]}
      </div>

      {/* History hint */}
      <div className="inv-tile-history-hint">
        <History size={11} />
        <span>View history</span>
      </div>
    </button>
  );
};

// ── Main BalancesGrid ─────────────────────────────────────────────────────────
export const BalancesGrid = () => {
  const { data: items = [], isLoading, isError, refetch, isFetching } = useInventoryBalances();
  const [selectedItem, setSelectedItem] = useState<ItemWithBrand | null>(null);

  if (isLoading) {
    return (
      <div className="inv-tiles-grid">
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className="inv-tile inv-tile-skeleton skeleton" />
        ))}
      </div>
    );
  }

  if (isError) {
    return (
      <div className="empty-state glass-panel">
        <AlertTriangle size={32} style={{ color: 'var(--danger)' }} />
        <p>Failed to load inventory balances.</p>
        <button className="btn btn-ghost" onClick={() => refetch()}>Retry</button>
      </div>
    );
  }

  if (items.length === 0) {
    return (
      <div className="empty-state glass-panel">
        <Package size={40} style={{ color: 'var(--text-muted)', opacity: 0.4 }} />
        <p style={{ color: 'var(--text-muted)' }}>No inventory items yet.</p>
        <p style={{ fontSize: '0.8rem', color: 'var(--text-muted)', opacity: 0.6 }}>
          Add items to start tracking your stock.
        </p>
      </div>
    );
  }

  return (
    <>
      {/* Toolbar */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1.25rem' }}>
        <p style={{ fontSize: '0.8rem', color: 'var(--text-muted)' }}>
          Click any product tile to view its full movement history.
        </p>
        <button
          className="btn btn-ghost"
          style={{ fontSize: '0.75rem', gap: '0.375rem' }}
          onClick={() => refetch()}
          disabled={isFetching}
        >
          <RefreshCw size={13} className={isFetching ? 'spin' : ''} />
          {isFetching ? 'Refreshing…' : 'Refresh'}
        </button>
      </div>

      {/* Tile grid */}
      <div className="inv-tiles-grid">
        {items.map((item) => (
          <ProductTile
            key={item.item_id}
            item={item}
            onClick={() => setSelectedItem(item)}
          />
        ))}
      </div>

      {/* Per-product history modal */}
      {selectedItem && (
        <ProductHistoryModal
          item={selectedItem}
          onClose={() => setSelectedItem(null)}
        />
      )}
    </>
  );
};
