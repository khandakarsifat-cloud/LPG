import { useState, type FormEvent } from 'react';
import { X, Package, Loader2 } from 'lucide-react';
import { useCreateItem } from '../../hooks/useInventory';
import type { CreateItemPayload, ItemType } from '../../types/inventory';

interface AddItemDialogProps {
  open: boolean;
  onClose: () => void;
}

const ITEM_TYPES: { value: ItemType; label: string; desc: string }[] = [
  { value: 'gas_only',      label: 'Gas Only',       desc: 'Refillable gas content, no cylinder asset tracked' },
  { value: 'cylinder_only', label: 'Cylinder Asset',  desc: 'Empty cylinder unit, no gas content' },
  { value: 'package',       label: 'Full Package',    desc: 'Filled cylinder — gas + cylinder together' },
];

export const AddItemDialog = ({ open, onClose }: AddItemDialogProps) => {
  const createItem = useCreateItem();

  const [form, setForm] = useState<CreateItemPayload>({
    brand:   '',
    size_kg: 12.5,
    type:    'package',
  });

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    await createItem.mutateAsync(form);
    onClose();
    setForm({ brand: '', size_kg: 12.5, type: 'package' });
  };

  if (!open) return null;

  return (
    <div className="dialog-backdrop" onClick={onClose}>
      <div
        className="dialog glass-panel"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label="Add New Item"
      >
        {/* Header */}
        <div className="dialog-header">
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            <div className="dialog-icon">
              <Package size={18} />
            </div>
            <div>
              <h2 className="dialog-title">Add New Item</h2>
              <p className="dialog-subtitle">Define a product SKU for the inventory ledger</p>
            </div>
          </div>
          <button className="dialog-close" onClick={onClose} aria-label="Close">
            <X size={18} />
          </button>
        </div>

        {/* Form */}
        <form onSubmit={handleSubmit}>
          <div className="dialog-body">
            {/* Brand */}
            <div className="input-group">
              <label className="input-label" htmlFor="item-brand">Brand / Supplier</label>
              <input
                id="item-brand"
                type="text"
                className="input-field"
                placeholder="e.g. Total, Oryx, Jamuna"
                value={form.brand}
                onChange={(e) => setForm((p) => ({ ...p, brand: e.target.value }))}
                required
                autoFocus
              />
            </div>

            {/* Size */}
            <div className="input-group">
              <label className="input-label" htmlFor="item-size">Weight (KG)</label>
              <input
                id="item-size"
                type="number"
                step="0.5"
                min="0.5"
                max="200"
                className="input-field"
                placeholder="e.g. 12.5"
                value={form.size_kg}
                onChange={(e) => setForm((p) => ({ ...p, size_kg: parseFloat(e.target.value) }))}
                required
              />
            </div>

            {/* Type */}
            <div className="input-group" style={{ marginBottom: 0 }}>
              <label className="input-label">Classification Type</label>
              <div className="item-type-grid">
                {ITEM_TYPES.map((t) => (
                  <button
                    key={t.value}
                    type="button"
                    className={`item-type-card ${form.type === t.value ? 'item-type-card-active' : ''}`}
                    onClick={() => setForm((p) => ({ ...p, type: t.value }))}
                  >
                    <div className="item-type-label">{t.label}</div>
                    <div className="item-type-desc">{t.desc}</div>
                  </button>
                ))}
              </div>
            </div>
          </div>

          {/* Footer */}
          <div className="dialog-footer">
            <button type="button" className="btn btn-ghost" onClick={onClose}>
              Cancel
            </button>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={createItem.isPending || !form.brand.trim()}
            >
              {createItem.isPending
                ? <><Loader2 size={15} className="spin" /> Creating…</>
                : 'Create Item'}
            </button>
          </div>

          {createItem.isError && (
            <div className="auth-error" style={{ margin: '0 1.5rem 1.5rem' }}>
              {(createItem.error as Error).message}
            </div>
          )}
        </form>
      </div>
    </div>
  );
};
