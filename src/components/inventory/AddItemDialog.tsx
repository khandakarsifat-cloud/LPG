import { useState, type FormEvent } from 'react';
import { X, Package, Loader2 } from 'lucide-react';
import { useCreateItem, useItems } from '../../hooks/useInventory';
import { useLPGBrands } from '../../hooks/useBrands';
import type { CreateItemPayload, CylinderWeight, MouthSize } from '../../types/inventory';
import { CYLINDER_WEIGHT_OPTIONS, MOUTH_SIZE_OPTIONS } from '../../types/inventory';

interface AddItemDialogProps {
  open: boolean;
  onClose: () => void;
}

export const AddItemDialog = ({ open, onClose }: AddItemDialogProps) => {
  const createItem = useCreateItem();
  const { data: brands = [] } = useLPGBrands();
  const { data: items = [] } = useItems();

  const [form, setForm] = useState<CreateItemPayload & { cylinder_weight?: CylinderWeight | null; mouth_size?: MouthSize | null }>({
    brand_id: null,
    brand: '',
    size_kg: 5,
    type: 'filled_gas',
    mouth_size: null,
  });

  const [duplicateError, setDuplicateError] = useState<string | null>(null);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setDuplicateError(null);

    if (!form.brand_id) {
      setDuplicateError('Please select a brand');
      return;
    }

    // Check for duplicate: same brand_id + size_kg
    const isDuplicate = items.some(
      (item) => item.brand_id === form.brand_id && item.size_kg === form.size_kg
    );

    if (isDuplicate) {
      setDuplicateError(`This product (${form.brand} ${form.size_kg}kg) already exists in your registry. Each product can only be added once.`);
      return;
    }

    await createItem.mutateAsync(form);
    onClose();
    setForm({ brand_id: null, brand: '', size_kg: 5, type: 'filled_gas', mouth_size: null });
    setDuplicateError(null);
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
            {/* Brand Selection */}
            <div className="input-group">
              <label className="input-label" htmlFor="item-brand">Brand</label>
              {brands.length === 0 ? (
                <div style={{ padding: '0.75rem', backgroundColor: 'var(--bg-secondary)', borderRadius: '0.375rem', fontSize: '0.875rem', color: 'var(--text-muted)' }}>
                  No brands available. Please add a brand in Settings first.
                </div>
              ) : (
                <select
                  id="item-brand"
                  className="input-field"
                  value={form.brand_id || ''}
                  onChange={(e) => {
                    const selected = brands.find((b) => b.brand_id === e.target.value);
                    setForm((p) => ({
                      ...p,
                      brand_id: e.target.value || null,
                      brand: selected?.brand_name || '',
                    }));
                  }}
                  required
                  autoFocus
                >
                  <option value="">Select a brand...</option>
                  {brands.filter((b) => b.is_active).map((brand) => (
                    <option key={brand.brand_id} value={brand.brand_id}>
                      {brand.brand_name}
                    </option>
                  ))}
                </select>
              )}
            </div>

            {/* Weight */}
            <div className="input-group">
              <label className="input-label" htmlFor="item-size">Cylinder Weight (KG) *</label>
              <select
                id="item-size"
                className="input-field"
                value={form.size_kg}
                onChange={(e) => setForm((p) => ({ ...p, size_kg: parseFloat(e.target.value) }))}
                required
              >
                <option value="">Select weight...</option>
                {CYLINDER_WEIGHT_OPTIONS.map((weight) => {
                  const weightNum = parseFloat(weight);
                  return (
                    <option key={weight} value={weightNum}>
                      {weight}
                    </option>
                  );
                })}
              </select>
            </div>

            {/* Mouth Size (Optional) */}
            <div className="input-group">
              <label className="input-label" htmlFor="mouth-size">Mouth Size (Optional)</label>
              <select
                id="mouth-size"
                className="input-field"
                value={form.mouth_size || ''}
                onChange={(e) => setForm((p) => ({ ...p, mouth_size: (e.target.value || null) as MouthSize | null }))}
              >
                <option value="">Select size...</option>
                {MOUTH_SIZE_OPTIONS.map((size) => (
                  <option key={size} value={size}>
                    {size}
                  </option>
                ))}
              </select>
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
              disabled={createItem.isPending || !form.brand_id}
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
          {duplicateError && (
            <div className="auth-error" style={{ margin: '0 1.5rem 1.5rem' }}>
              {duplicateError}
            </div>
          )}
        </form>
      </div>
    </div>
  );
};
