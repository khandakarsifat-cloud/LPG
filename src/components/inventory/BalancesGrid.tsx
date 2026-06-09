import { Package, TrendingUp, TrendingDown, AlertTriangle, RefreshCw, Droplets, Box } from 'lucide-react';
import { useInventoryBalances } from '../../hooks/useInventory';

// ── Single quantity card ───────────────────────────────────────────────────────
interface QtyCardProps {
  label: string;
  icon: React.ReactNode;
  accent: string;
  qty: number;
  lastUpdated?: string;
}

const QtyCard = ({ label, icon, accent, qty, lastUpdated }: QtyCardProps) => {
  const isLow  = qty > 0 && qty <= 10;
  const isEmpty = qty <= 0;
  const statusColor = isEmpty ? 'var(--danger)' : isLow ? 'var(--warning)' : accent;

  return (
    <div style={{
      flex: 1,
      background: `${accent}08`,
      border: `1px solid ${statusColor}30`,
      borderRadius: '0.625rem',
      padding: '0.875rem 1rem',
      display: 'flex',
      flexDirection: 'column',
      gap: '0.5rem',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', color: accent, fontSize: '0.75rem', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
          {icon}
          {label}
        </div>
        <span style={{
          fontSize: '0.7rem',
          fontWeight: 600,
          padding: '0.15rem 0.5rem',
          borderRadius: '0.25rem',
          background: isEmpty ? 'rgba(239,68,68,0.12)' : isLow ? 'rgba(245,158,11,0.12)' : `${accent}18`,
          color: statusColor,
        }}>
          {isEmpty ? 'Out of Stock' : isLow ? 'Low Stock' : 'In Stock'}
        </span>
      </div>

      <div style={{ display: 'flex', alignItems: 'baseline', gap: '0.35rem' }}>
        <span style={{ fontSize: '2rem', fontWeight: 700, color: statusColor, lineHeight: 1 }}>
          {qty.toLocaleString()}
        </span>
        <span style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>units</span>
      </div>

      {lastUpdated && (
        <div style={{ fontSize: '0.7rem', color: 'var(--text-muted)', display: 'flex', alignItems: 'center', gap: '0.25rem' }}>
          {qty > 0
            ? <TrendingUp size={11} style={{ color: 'var(--accent)' }} />
            : <TrendingDown size={11} style={{ color: 'var(--danger)' }} />}
          Updated {new Date(lastUpdated).toLocaleTimeString()}
        </div>
      )}
    </div>
  );
};

// ── Main BalancesGrid ─────────────────────────────────────────────────────────
export const BalancesGrid = () => {
  const { data: items = [], isLoading, isError, refetch, isFetching } = useInventoryBalances();

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

      <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
        {items.map((item) => {
          const specs: string[] = [];
          if (item.cylinder_weight) specs.push(item.cylinder_weight);
          if (item.mouth_size)      specs.push(item.mouth_size);

          return (
            <div
              key={item.item_id}
              className="glass-panel"
              style={{ padding: '1rem 1.25rem' }}
            >
              {/* Group header */}
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '0.875rem' }}>
                <div>
                  <div style={{ fontWeight: 700, fontSize: '1rem' }}>
                    {item.brand} <span style={{ color: 'var(--text-muted)', fontWeight: 400 }}>{item.size_kg}kg</span>
                  </div>
                  {specs.length > 0 && (
                    <div style={{ fontSize: '0.75rem', color: 'var(--text-muted)', marginTop: '0.1rem' }}>
                      {specs.join(', ')}
                    </div>
                  )}
                </div>
              </div>

              {/* Side-by-side Filled + Empty cards */}
              <div style={{ display: 'flex', gap: '0.75rem' }}>
                <QtyCard
                  label="Filled Gas"
                  icon={<Droplets size={12} />}
                  accent="var(--primary)"
                  qty={item.filled_quantity || 0}
                  lastUpdated={item.updated_at || item.created_at}
                />
                <QtyCard
                  label="Empty Cylinder"
                  icon={<Box size={12} />}
                  accent="var(--warning)"
                  qty={item.empty_quantity || 0}
                  lastUpdated={item.updated_at || item.created_at}
                />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};
