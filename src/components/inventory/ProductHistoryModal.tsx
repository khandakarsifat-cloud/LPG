import { X, ArrowUpCircle, ArrowDownCircle, Activity, Loader2, Package } from 'lucide-react';
import { useItemMovements } from '../../hooks/useInventory';
import { MOVEMENT_TYPE_LABELS, MOVEMENT_TYPE_COLORS, type MovementType, type ItemWithBrand } from '../../types/inventory';
import { formatDistanceToNow, format } from 'date-fns';
import './inventory.css';

interface ProductHistoryModalProps {
  item: ItemWithBrand;
  onClose: () => void;
}

export const ProductHistoryModal = ({ item, onClose }: ProductHistoryModalProps) => {
  const { data: movements = [], isLoading } = useItemMovements(item.item_id);

  const brandName = item.lpg_brands?.brand_name ?? item.brand;

  return (
    /* ── backdrop ── */
    <div className="phm-backdrop" onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      {/* ── panel ── */}
      <div className="phm-panel glass-panel">

        {/* Header */}
        <div className="phm-header">
          <div className="phm-header-left">
            <div className="phm-product-icon">
              <Package size={20} />
            </div>
            <div>
              <div className="phm-title">{brandName} <span className="phm-size">{item.size_kg} kg</span></div>
              <div className="phm-subtitle">Movement History</div>
            </div>
          </div>

          {/* Current stock pills */}
          <div className="phm-stock-pills">
            <div className="phm-stock-pill phm-stock-filled">
              <span className="phm-stock-pill-label">Filled</span>
              <span className="phm-stock-pill-value">{item.filled_quantity ?? 0}</span>
            </div>
            <div className="phm-stock-pill phm-stock-empty">
              <span className="phm-stock-pill-label">Empty</span>
              <span className="phm-stock-pill-value">{item.empty_quantity ?? 0}</span>
            </div>
            <button className="phm-close" onClick={onClose} aria-label="Close">
              <X size={18} />
            </button>
          </div>
        </div>

        {/* Divider */}
        <div className="phm-divider" />

        {/* Body */}
        <div className="phm-body">
          {isLoading ? (
            <div className="phm-loading">
              <Loader2 size={28} className="spin" style={{ color: 'var(--primary)' }} />
              <p>Loading history…</p>
            </div>
          ) : movements.length === 0 ? (
            <div className="phm-empty">
              <Activity size={36} style={{ opacity: 0.3 }} />
              <p>No movements recorded yet for this product.</p>
            </div>
          ) : (
            <div className="phm-feed">
              {movements.map((m) => {
                const color   = MOVEMENT_TYPE_COLORS[m.movement_type as MovementType] ?? '#94a3b8';
                const label   = MOVEMENT_TYPE_LABELS[m.movement_type as MovementType] ?? m.movement_type;
                const isUp    = (m.filled_quantity_change > 0) || (m.empty_quantity_change > 0);
                const actor   = m.user_profiles?.email?.split('@')[0] ?? 'System';
                const hasFilled = m.filled_quantity_change !== 0;
                const hasEmpty  = m.empty_quantity_change !== 0;

                return (
                  <div key={m.movement_id} className="phm-entry">
                    {/* Left icon */}
                    <div className="phm-entry-icon" style={{ color }}>
                      {isUp
                        ? <ArrowUpCircle size={20} />
                        : <ArrowDownCircle size={20} />}
                    </div>

                    {/* Middle info */}
                    <div className="phm-entry-info">
                      <div className="phm-entry-top">
                        <span className="phm-type-badge" style={{ background: `${color}18`, color }}>
                          {label}
                        </span>
                        <span className="phm-entry-actor">by {actor}</span>
                      </div>
                      {m.notes && (
                        <div className="phm-entry-notes">{m.notes}</div>
                      )}
                      <div className="phm-entry-time">
                        {format(new Date(m.created_at), 'dd MMM yyyy, HH:mm')}
                        &nbsp;·&nbsp;
                        {formatDistanceToNow(new Date(m.created_at), { addSuffix: true })}
                      </div>
                    </div>

                    {/* Right qty changes */}
                    <div className="phm-entry-qty">
                      {hasFilled && (
                        <span
                          className="phm-qty-chip"
                          style={{
                            color:      m.filled_quantity_change > 0 ? 'var(--accent)' : 'var(--danger)',
                            background: m.filled_quantity_change > 0 ? 'rgba(16,185,129,0.12)' : 'rgba(239,68,68,0.12)',
                          }}
                        >
                          {m.filled_quantity_change > 0 ? '+' : ''}{m.filled_quantity_change} Filled
                        </span>
                      )}
                      {hasEmpty && (
                        <span
                          className="phm-qty-chip"
                          style={{
                            color:      m.empty_quantity_change > 0 ? 'var(--warning)' : 'var(--danger)',
                            background: m.empty_quantity_change > 0 ? 'rgba(245,158,11,0.12)' : 'rgba(239,68,68,0.12)',
                          }}
                        >
                          {m.empty_quantity_change > 0 ? '+' : ''}{m.empty_quantity_change} Empty
                        </span>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="phm-footer">
          <span className="phm-footer-note">
            {!isLoading && `${movements.length} entr${movements.length === 1 ? 'y' : 'ies'} · Immutable ledger`}
          </span>
          <button className="btn btn-ghost" style={{ fontSize: '0.8rem' }} onClick={onClose}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
};
