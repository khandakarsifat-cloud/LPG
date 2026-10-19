import { useState } from 'react';
import { Package, AlertTriangle, RefreshCw, Droplets, Box, History, Check } from 'lucide-react';
import { useInventoryBalances } from '../../hooks/useInventory';
import { useLPGBrands } from '../../hooks/useBrands';
import { groupInventoryByBrand } from '../../lib/inventoryGroups';
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
  selected?: boolean;
}

export const ProductTile = ({ item, onClick, selected }: TileProps) => {
  const filled  = item.filled_quantity ?? 0;
  const empty   = item.empty_quantity  ?? 0;
  const status  = getStockStatus(filled, empty);
  const color   = STATUS_COLOR[status];
  const brandName = item.lpg_brands?.brand_name ?? item.brand;

  return (
    <button type="button" className={`inv-tile${selected ? ' inv-tile-selected' : ''}`} onClick={onClick}
      aria-pressed={selected} title={`${brandName} ${item.size_kg}kg ${item.mouth_size ?? ''} — ${selected === undefined ? 'view product details' : 'select product'}`}>
      {/* Status dot */}
      {selected === undefined ? <span className="inv-tile-dot" style={{ background: color }} />
        : <span className="inv-tile-check" aria-hidden="true">{selected && <Check size={14} />}</span>}

      {/* Brand + size */}
      <div className="inv-tile-brand">{brandName}</div>
      <div className="inv-tile-size">{item.size_kg} <span>kg</span> {item.mouth_size && <small className="inv-mouth-size">{item.mouth_size}</small>}</div>

      {/* Stock counts */}
      <div className="inv-tile-counts">
        <div className="inv-tile-count inv-tile-count-filled" title="Filled" aria-label={`${filled} filled`}>
          <Droplets size={11} />
          <span>{filled}</span>
        </div>
        <div className="inv-tile-count inv-tile-count-empty" title="Empty" aria-label={`${empty} empty`}>
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
        {selected === undefined && <History size={11} />}
        <span>{selected === undefined ? 'Product details' : selected ? 'Selected' : 'Select product'}</span>
      </div>
    </button>
  );
};

// ── Main BalancesGrid ─────────────────────────────────────────────────────────
export const BalancesGrid = () => {
  const { data: items = [], isLoading, isError, refetch, isFetching } = useInventoryBalances();
  const brands = useLPGBrands();
  const [selectedItem, setSelectedItem] = useState<ItemWithBrand | null>(null);

  if (isLoading || brands.isPending) {
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
          Select a product for prices, buying costs and weekly history.
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
      <div className="inv-brand-groups">
        {brands.isError && <p className="product-error" role="alert">Could not load saved brand order. <button className="btn btn-ghost" onClick={() => brands.refetch()}>Retry</button></p>}
        {groupInventoryByBrand(items, brands.data ?? []).map(group => <section className="inv-brand-group" key={group.key} aria-label={`${group.name} products`}>
          <h3 className="inv-brand-heading">{group.name}</h3>
          <div className="inv-tiles-grid">{group.items.map(item => <ProductTile key={item.item_id} item={item} onClick={() => setSelectedItem(item)} />)}</div>
        </section>)}
      </div>

      {/* Per-product history modal */}
      {selectedItem && (
        <ProductHistoryModal
          item={items.find(item => item.item_id === selectedItem.item_id) ?? selectedItem}
          onClose={() => setSelectedItem(null)}
        />
      )}
    </>
  );
};
