import { ArrowUpCircle, ArrowDownCircle, Activity } from 'lucide-react';
import { useInventoryMovements } from '../../hooks/useInventory';
import { MOVEMENT_TYPE_LABELS, MOVEMENT_TYPE_COLORS, type MovementType } from '../../types/inventory';
import { formatDistanceToNow } from 'date-fns';

export const MovementsFeed = () => {
  const { data: movements = [], isLoading } = useInventoryMovements(60);

  if (isLoading) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: '0.75rem' }}>
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className="movement-row skeleton" style={{ height: '62px', borderRadius: 'var(--radius-md)' }} />
        ))}
      </div>
    );
  }

  if (movements.length === 0) {
    return (
      <div className="empty-state" style={{ padding: '3rem 1rem' }}>
        <Activity size={32} style={{ color: 'var(--text-muted)', opacity: 0.4 }} />
        <p style={{ color: 'var(--text-muted)', fontSize: '0.875rem' }}>No movements recorded yet.</p>
      </div>
    );
  }

  return (
    <div className="movements-feed">
      {movements.map((m) => {
        const hasFilled = m.filled_quantity_change !== 0;
        const hasEmpty  = m.empty_quantity_change !== 0;
        const isPositive = (m.filled_quantity_change > 0) || (m.empty_quantity_change > 0);
        const color = MOVEMENT_TYPE_COLORS[m.movement_type as MovementType];
        const item = m.items;
        const actor = m.user_profiles?.full_name ?? 'System';

        return (
          <div key={m.movement_id} className="movement-row">
            {/* Icon */}
            <div className="movement-icon" style={{ color }}>
              {isPositive
                ? <ArrowUpCircle size={20} />
                : <ArrowDownCircle size={20} />}
            </div>

            {/* Info */}
            <div className="movement-info">
              <div className="movement-item-name">
                {item ? `${item.brand} ${item.size_kg}kg` : '—'}
              </div>
              <div className="movement-meta">
                <span className="movement-type-badge" style={{ background: `${color}18`, color }}>
                  {MOVEMENT_TYPE_LABELS[m.movement_type as MovementType]}
                </span>
                <span style={{ color: 'var(--text-muted)', fontSize: '0.7rem' }}>
                  by {actor}
                </span>
                {m.notes && (
                  <span style={{ color: 'var(--text-muted)', fontSize: '0.7rem', fontStyle: 'italic' }}>
                    · {m.notes}
                  </span>
                )}
              </div>
            </div>

            {/* Quantity + time */}
            <div className="movement-right">
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: '0.1rem' }}>
                {hasFilled && (
                  <span
                    className="movement-qty"
                    style={{ color: m.filled_quantity_change > 0 ? 'var(--accent)' : 'var(--danger)', fontSize: '0.85rem' }}
                  >
                    {m.filled_quantity_change > 0 ? '+' : ''}{m.filled_quantity_change.toLocaleString()} Filled
                  </span>
                )}
                {hasEmpty && (
                  <span
                    className="movement-qty"
                    style={{ color: m.empty_quantity_change > 0 ? 'var(--warning)' : 'var(--danger)', fontSize: '0.85rem' }}
                  >
                    {m.empty_quantity_change > 0 ? '+' : ''}{m.empty_quantity_change.toLocaleString()} Empty
                  </span>
                )}
              </div>
              <span className="movement-time">
                {formatDistanceToNow(new Date(m.created_at), { addSuffix: true })}
              </span>
            </div>
          </div>
        );
      })}
    </div>
  );
};
