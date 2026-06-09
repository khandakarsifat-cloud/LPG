import { useState, type FormEvent } from 'react';
import { X, ShieldAlert, Loader2 } from 'lucide-react';
import { useCreateMovement, useItems } from '../../hooks/useInventory';
import { MOVEMENT_TYPE_LABELS, type MovementType } from '../../types/inventory';

interface AdjustmentModalProps {
  open: boolean;
  onClose: () => void;
}

const ADMIN_MOVEMENT_TYPES: MovementType[] = [
  'purchase', 'refill', 'adjust_gain', 'adjust_loss', 'loss',
];

export const AdjustmentModal = ({ open, onClose }: AdjustmentModalProps) => {
  const { data: items = [], isLoading: itemsLoading } = useItems();
  const createMovement = useCreateMovement();

  const [form, setForm] = useState({
    item_id:       '',
    movement_type: 'purchase' as MovementType,
    filled_quantity: 0,
    empty_quantity:  0,
    notes:         '',
  });

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (form.filled_quantity === 0 && form.empty_quantity === 0) return;
    
    await createMovement.mutateAsync({
      item_id:       form.item_id,
      movement_type: form.movement_type,
      filled_quantity_change: form.filled_quantity,
      empty_quantity_change:  form.empty_quantity,
      notes:         form.notes || undefined,
    });
    onClose();
    setForm({ item_id: '', movement_type: 'purchase', filled_quantity: 0, empty_quantity: 0, notes: '' });
  };

  if (!open) return null;

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div
        className="modal-content glass-panel"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label="Stock Adjustment"
      >
        {/* Header */}
        <div className="modal-header">
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            <div className="modal-icon" style={{ background: 'rgba(245, 158, 11, 0.1)', color: 'var(--warning)' }}>
              <ShieldAlert size={18} />
            </div>
            <div>
              <h2 className="modal-title">Stock Adjustment</h2>
              <p className="modal-subtitle">Injects an immutable entry into the inventory ledger</p>
            </div>
          </div>
          <button className="modal-close" onClick={onClose} aria-label="Close">
            <X size={18} />
          </button>
        </div>

        <form onSubmit={handleSubmit}>
          <div className="modal-body">
            {/* Item selector */}
            <div className="input-group">
              <label className="input-label" htmlFor="adj-item">Select Item</label>
              <select
                id="adj-item"
                className="input-field"
                value={form.item_id}
                onChange={(e) => setForm((p) => ({ ...p, item_id: e.target.value }))}
                required
              >
                <option value="">
                  {itemsLoading ? 'Loading items…' : '— Choose an item —'}
                </option>
                {items.map((item) => (
                  <option key={item.item_id} value={item.item_id}>
                    {item.brand} {item.size_kg}kg
                  </option>
                ))}
              </select>
            </div>

            {/* Movement type */}
            <div className="input-group">
              <label className="input-label">Movement Type</label>
              <div className="movement-type-grid">
                {ADMIN_MOVEMENT_TYPES.map((type) => (
                  <button
                    key={type}
                    type="button"
                    className={`movement-type-chip ${form.movement_type === type ? 'movement-type-chip-active' : ''}`}
                    onClick={() => setForm((p) => ({ ...p, movement_type: type }))}
                  >
                    {MOVEMENT_TYPE_LABELS[type]}
                  </button>
                ))}
              </div>
            </div>

            {/* Quantity */}
            <div style={{ display: 'flex', gap: '1rem' }}>
              <div className="input-group" style={{ flex: 1 }}>
                <label className="input-label" htmlFor="adj-filled-qty">Filled Quantity</label>
                <input
                  id="adj-filled-qty"
                  type="number"
                  min="0"
                  className="input-field"
                  value={form.filled_quantity}
                  onChange={(e) => setForm((p) => ({ ...p, filled_quantity: parseInt(e.target.value) || 0 }))}
                />
              </div>
              <div className="input-group" style={{ flex: 1 }}>
                <label className="input-label" htmlFor="adj-empty-qty">Empty Quantity</label>
                <input
                  id="adj-empty-qty"
                  type="number"
                  min="0"
                  className="input-field"
                  value={form.empty_quantity}
                  onChange={(e) => setForm((p) => ({ ...p, empty_quantity: parseInt(e.target.value) || 0 }))}
                />
              </div>
            </div>
            <div style={{ fontSize: '0.75rem', color: 'var(--text-muted)', marginTop: '-0.5rem', marginBottom: '1.25rem' }}>
              (sign applied automatically by movement type)
            </div>

            {/* Notes */}
            <div className="input-group" style={{ marginBottom: 0 }}>
              <label className="input-label" htmlFor="adj-notes">Reason / Notes</label>
              <textarea
                id="adj-notes"
                className="input-field"
                rows={3}
                placeholder="e.g. Physical count reconciliation, damage during transit…"
                value={form.notes}
                onChange={(e) => setForm((p) => ({ ...p, notes: e.target.value }))}
                style={{ resize: 'vertical', minHeight: '80px' }}
              />
            </div>
          </div>

          <div className="modal-footer">
            <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
            <button
              type="submit"
              className="btn btn-primary"
              style={{ background: 'var(--warning)', boxShadow: '0 2px 10px rgba(245,158,11,0.3)' }}
              disabled={createMovement.isPending || !form.item_id || (form.filled_quantity === 0 && form.empty_quantity === 0)}
            >
              {createMovement.isPending
                ? <><Loader2 size={15} className="spin" /> Posting…</>
                : 'Post to Ledger'}
            </button>
          </div>

          {createMovement.isError && (
            <div className="auth-error" style={{ margin: '0 1.5rem 1.5rem' }}>
              {(createMovement.error as Error).message}
            </div>
          )}
        </form>
      </div>
    </div>
  );
};
