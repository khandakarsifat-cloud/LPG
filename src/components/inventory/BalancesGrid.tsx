import { Package, TrendingUp, TrendingDown, AlertTriangle, RefreshCw } from 'lucide-react';
import { useInventoryBalances } from '../../hooks/useInventory';
import { ITEM_TYPE_LABELS, type ItemType } from '../../types/inventory';

const TYPE_ACCENT: Record<ItemType, string> = {
  package:       'var(--primary)',
  gas_only:      'var(--accent)',
  cylinder_only: 'var(--warning)',
};

export const BalancesGrid = () => {
  const { data: balances = [], isLoading, isError, refetch, isFetching } = useInventoryBalances();

  if (isLoading) {
    return (
      <div className="balances-placeholder">
        {Array.from({ length: 4 }).map((_, i) => (
          <div key={i} className="balance-card glass-panel skeleton" />
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

  if (balances.length === 0) {
    return (
      <div className="empty-state glass-panel">
        <Package size={40} style={{ color: 'var(--text-muted)', opacity: 0.4 }} />
        <p style={{ color: 'var(--text-muted)' }}>No inventory items yet.</p>
        <p style={{ fontSize: '0.8rem', color: 'var(--text-muted)', opacity: 0.6 }}>
          Create items and post purchase movements to see balances here.
        </p>
      </div>
    );
  }

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: '0.75rem' }}>
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

      <div className="balances-grid">
        {balances.map((b) => {
          const item = b.items;
          if (!item) return null;
          const qty = b.current_quantity;
          const accent = TYPE_ACCENT[item.type as ItemType];
          const isLow = qty > 0 && qty <= 10;
          const isEmpty = qty <= 0;

          return (
            <div
              key={b.item_id}
              className="balance-card glass-panel"
              style={{ borderLeft: `3px solid ${isEmpty ? 'var(--danger)' : isLow ? 'var(--warning)' : accent}` }}
            >
              <div className="balance-card-header">
                <div className="balance-card-icon" style={{ background: `${accent}18`, color: accent }}>
                  <Package size={16} />
                </div>
                <span className={`balance-status-badge ${isEmpty ? 'badge-danger' : isLow ? 'badge-warning' : 'badge-success'}`}>
                  {isEmpty ? 'Out of Stock' : isLow ? 'Low Stock' : 'In Stock'}
                </span>
              </div>

              <div className="balance-card-name">
                {item.brand} {item.size_kg}kg
              </div>
              <div className="balance-card-type">
                {ITEM_TYPE_LABELS[item.type as ItemType]}
              </div>

              <div className="balance-card-qty" style={{ color: isEmpty ? 'var(--danger)' : isLow ? 'var(--warning)' : 'var(--text-main)' }}>
                {qty.toLocaleString()}
                <span className="balance-card-qty-unit">units</span>
              </div>

              <div className="balance-card-footer">
                {qty > 0
                  ? <TrendingUp size={13} style={{ color: 'var(--accent)' }} />
                  : <TrendingDown size={13} style={{ color: 'var(--danger)' }} />}
                <span style={{ fontSize: '0.7rem', color: 'var(--text-muted)' }}>
                  Updated {new Date(b.last_updated).toLocaleTimeString()}
                </span>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};
