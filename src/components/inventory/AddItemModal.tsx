import { useState, type FormEvent } from 'react';
import { Loader2 } from 'lucide-react';
import { useCreateItem, useInventoryBalances } from '../../hooks/useInventory';
import { useLPGBrands } from '../../hooks/useBrands';
import { useBusinessCatalogs } from '../../hooks/useBusinessSettings';
import type { CreateItemPayload, MouthSize } from '../../types/inventory';
import { MOUTH_SIZE_OPTIONS } from '../../types/inventory';
import { PurchaseDialog } from '../purchases/PurchaseControls';

interface AddItemModalProps {
  open: boolean;
  onClose: () => void;
}

type FormState = CreateItemPayload;

export const AddItemModal = ({ open, onClose }: AddItemModalProps) => open ? <AddItemForm onClose={onClose} /> : null;

function AddItemForm({ onClose }: Pick<AddItemModalProps, 'onClose'>) {
  const createItem = useCreateItem();
  const catalogs = useBusinessCatalogs();
  const weights = catalogs.data?.weights.filter(weight => weight.active).map(weight => weight.size_kg) ?? [];
  const { data: brands = [] } = useLPGBrands();
  const { data: items = [] } = useInventoryBalances();

  const [form, setForm] = useState<FormState>({
    brand_id: '',
    size_kg: 0,
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

    if (!weights.includes(form.size_kg)) { setDuplicateError('Select an available weight from Settings'); return; }

    // Check for duplicate: brand_id + size_kg + mouth_size (all three must match)
    const exists = items.some(
      (i) => i.brand_id === form.brand_id && i.size_kg === form.size_kg && i.mouth_size === form.mouth_size
    );

    if (exists) {
      setDuplicateError(
        `${brands.find(b => b.brand_id === form.brand_id)?.brand_name ?? 'Product'} ${form.size_kg}kg (${form.mouth_size}) already exists. Same brand+weight+mouth size cannot be duplicated.`
      );
      return;
    }

    setIsSubmitting(true);
    try {
      await createItem.mutateAsync({
        brand_id:        form.brand_id,
        size_kg:         form.size_kg,
        mouth_size:      form.mouth_size,
      });

      onClose();
      setForm({ brand_id: '', size_kg: 0, mouth_size: '22mm' });
    } catch {
      // error displayed via createItem.isError
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <PurchaseDialog title="Add New Item" subtitle="Register an LPG product, then add stock through a purchase or valued adjustment." onClose={onClose} busy={isSubmitting}>
        {/* Form */}
        <form onSubmit={handleSubmit}>
          <div className="modal-body dialog-form"><div className="lpg-product-form"><div className="product-identity-fields">
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
                    setForm((p) => ({
                      ...p,
                      brand_id: e.target.value,
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
                value={form.size_kg || ''}
                onChange={(e) => setForm((p) => ({ ...p, size_kg: parseFloat(e.target.value) }))}
                required
              >
                <option value="">Select weight...</option>
                {weights.map((weight) => {
                  const weightNum = weight;
                  return (
                    <option key={weight} value={weightNum}>
                      {weight}kg
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
          </div></div></div>

          {/* Footer */}
          <div className="modal-footer">
            <button type="button" className="btn btn-ghost" disabled={isSubmitting} onClick={onClose}>
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
    </PurchaseDialog>
  );
}
