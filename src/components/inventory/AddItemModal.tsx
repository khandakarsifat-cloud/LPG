import { useState, type FormEvent } from 'react';
import { X, Package, Loader2 } from 'lucide-react';
import { useCreateItem, useItems } from '../../hooks/useInventory';
import { useLPGBrands } from '../../hooks/useBrands';
import type { CreateItemPayload, MouthSize } from '../../types/inventory';
import { CYLINDER_WEIGHT_OPTIONS, MOUTH_SIZE_OPTIONS } from '../../types/inventory';

interface AddItemModalProps {
  open: boolean;
  onClose: () => void;
}

type FormState = CreateItemPayload;

export const AddItemModal = ({ open, onClose }: AddItemModalProps) => {
  const createItem = useCreateItem();
  const { data: brands = [] } = useLPGBrands();
  const { data: items = [] } = useItems();

  const [form, setForm] = useState<FormState>({
    brand_id: null,
    brand: '',
    size_kg: 5,
    cylinder_weight: null,
    mouth_size: '22mm',  // default
  });

  const [duplicateError, setDuplicateError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setDuplicateError(null);

    if (!form.brand_id) {
      setDuplicateError('Please select a brand');
      return;
    }

    if (!form.mouth_size) {
      setDuplicateError('Please select a mouth size');
      return;
    }

    // Check for duplicate: brand_id + size_kg + mouth_size (all three must match)
    const exists = items.some(
      (i) => i.brand_id === form.brand_id && i.size_kg === form.size_kg && i.mouth_size === form.mouth_size
    );

    if (exists) {
      setDuplicateError(
        `${form.brand} ${form.size_kg}kg (${form.mouth_size}) already exists. Same brand+weight+mouth size cannot be duplicated.`
      );
      return;
    }

    setIsSubmitting(true);
    try {
      await createItem.mutateAsync({
        brand_id:        form.brand_id,
        brand:           form.brand,
        size_kg:         form.size_kg,
        cylinder_weight: form.cylinder_weight ?? null,
        mouth_size:      form.mouth_size,
      });

      onClose();
      setForm({ brand_id: null, brand: '', size_kg: 5, cylinder_weight: null, mouth_size: '22mm' });
    } catch {
      // error displayed via createItem.isError
    } finally {
      setIsSubmitting(false);
    }
  };

  if (!open) return null;

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div
        className="modal-content glass-panel"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label="Add New Item"
      >
        {/* Header */}
        <div className="modal-header">
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            <div className="modal-icon">
              <Package size={18} />
            </div>
            <div>
              <h2 className="modal-title">Add New Item</h2>
              <p className="modal-subtitle">
                Register a new cylinder SKU (tracks both filled and empty stocks)
              </p>
            </div>
          </div>
          <button className="modal-close" onClick={onClose} aria-label="Close">
            <X size={18} />
          </button>
        </div>

        {/* Form */}
        <form onSubmit={handleSubmit}>
          <div className="modal-body">
            {/* Brand Selection */}
            <div className="input-group">
              <label className="input-label" htmlFor="item-brand">Brand *</label>
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

            {/* Mouth Size — required */}
            <div className="input-group">
              <label className="input-label" htmlFor="mouth-size">Mouth Size *</label>
              <select
                id="mouth-size"
                className="input-field"
                value={form.mouth_size || ''}
                onChange={(e) => setForm((p) => ({ ...p, mouth_size: (e.target.value || null) as MouthSize | null }))}
                required
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
          <div className="modal-footer">
            <button type="button" className="btn btn-ghost" onClick={onClose}>
              Cancel
            </button>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={isSubmitting || !form.brand_id}
            >
              {isSubmitting
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
