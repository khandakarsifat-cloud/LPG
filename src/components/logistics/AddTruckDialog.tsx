import { useState, type FormEvent } from 'react';
import { X, Truck as TruckIcon, Loader2 } from 'lucide-react';
import { useCreateTruck } from '../../hooks/useLogistics';
import type { CreateTruckPayload, TruckSize } from '../../types/logistics';
import { TRUCK_SIZE_OPTIONS, TRUCK_SIZE_LABELS, TRUCK_SIZE_DESCRIPTIONS } from '../../types/logistics';

interface AddTruckDialogProps {
  open: boolean;
  onClose: () => void;
}

export const AddTruckDialog = ({ open, onClose }: AddTruckDialogProps) => {
  const createTruck = useCreateTruck();

  const [form, setForm] = useState<CreateTruckPayload>({
    name: '',
    serial_no: '',
    capacity: 20,
    size: 'medium',
  });

  const [validationError, setValidationError] = useState<string | null>(null);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setValidationError(null);

    // Validation
    if (!form.name.trim()) {
      setValidationError('Truck name is required');
      return;
    }
    if (!form.serial_no.trim()) {
      setValidationError('Serial number is required');
      return;
    }
    if (form.capacity <= 0) {
      setValidationError('Capacity must be greater than 0');
      return;
    }

    try {
      await createTruck.mutateAsync(form);
      onClose();
      setForm({ name: '', serial_no: '', capacity: 20, size: 'medium' });
      setValidationError(null);
    } catch (error) {
      const err = error as Error;
      if (err.message.includes('unique')) {
        setValidationError(`A truck with serial number "${form.serial_no}" already exists`);
      } else {
        setValidationError(err.message);
      }
    }
  };

  if (!open) return null;

  return (
    <div className="dialog-backdrop" onClick={onClose}>
      <div
        className="dialog glass-panel"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label="Add New Truck"
      >
        {/* Header */}
        <div className="dialog-header">
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            <div className="dialog-icon">
              <TruckIcon size={18} />
            </div>
            <div>
              <h2 className="dialog-title">Add New Truck</h2>
              <p className="dialog-subtitle">Register a vehicle for your logistics fleet</p>
            </div>
          </div>
          <button className="dialog-close" onClick={onClose} aria-label="Close">
            <X size={18} />
          </button>
        </div>

        {/* Form */}
        <form onSubmit={handleSubmit}>
          <div className="dialog-body">
            {/* Truck Name */}
            <div className="input-group">
              <label className="input-label" htmlFor="truck-name">
                Truck Name *
              </label>
              <input
                id="truck-name"
                type="text"
                className="input-field"
                placeholder="e.g., JAC, Ashok Leyland, Tata"
                value={form.name}
                onChange={(e) => setForm((p) => ({ ...p, name: e.target.value }))}
                required
                autoFocus
              />
            </div>

            {/* Serial Number */}
            <div className="input-group">
              <label className="input-label" htmlFor="serial-no">
                Serial Number (Registration) *
              </label>
              <input
                id="serial-no"
                type="text"
                className="input-field"
                placeholder="e.g., DL01AB1234"
                value={form.serial_no}
                onChange={(e) => setForm((p) => ({ ...p, serial_no: e.target.value }))}
                required
              />
            </div>

            {/* Capacity */}
            <div className="input-group">
              <label className="input-label" htmlFor="capacity">
                Capacity (Units) *
              </label>
              <input
                id="capacity"
                type="number"
                className="input-field"
                min="1"
                step="1"
                value={form.capacity}
                onChange={(e) => setForm((p) => ({ ...p, capacity: parseInt(e.target.value, 10) }))}
                required
              />
            </div>

            {/* Size */}
            <div className="input-group" style={{ marginBottom: 0 }}>
              <label className="input-label" htmlFor="truck-size">
                Size *
              </label>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '0.75rem' }}>
                {TRUCK_SIZE_OPTIONS.map((sizeOption) => (
                  <button
                    key={sizeOption}
                    type="button"
                    className={`item-type-card ${form.size === sizeOption ? 'item-type-card-active' : ''}`}
                    onClick={() => setForm((p) => ({ ...p, size: sizeOption as TruckSize }))}
                  >
                    <div className="item-type-label">{TRUCK_SIZE_LABELS[sizeOption]}</div>
                    <div className="item-type-desc">{TRUCK_SIZE_DESCRIPTIONS[sizeOption]}</div>
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
              disabled={createTruck.isPending}
            >
              {createTruck.isPending
                ? <><Loader2 size={15} className="spin" /> Adding…</>
                : 'Add Truck'}
            </button>
          </div>

          {(createTruck.isError || validationError) && (
            <div className="auth-error" style={{ margin: '0 1.5rem 1.5rem' }}>
              {validationError || (createTruck.error as Error).message}
            </div>
          )}
        </form>
      </div>
    </div>
  );
};
