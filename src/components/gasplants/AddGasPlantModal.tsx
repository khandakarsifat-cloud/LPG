import { useState, type FormEvent, useEffect } from 'react';
import { X, Factory, Loader2, Phone, Mail } from 'lucide-react';
import {
  useCreateGasPlant,
  useUpdateGasPlant,
  useCreateAreaOfficer,
  useUpdateAreaOfficer,
} from '../../hooks/useGasPlants';
import { useLPGBrands } from '../../hooks/useBrands';
import type { GasPlant } from '../../types/gasPlants';

interface AddGasPlantModalProps {
  open:        boolean;
  onClose:     () => void;
  editingPlant?: GasPlant | null;
}

const EMPTY_FORM = {
  plant_name: '',
  brand_id: '',
  location: '',
  officer_name: '',
  whatsapp_phone: '',
  email: '',
};

export const AddGasPlantModal = ({ open, onClose, editingPlant }: AddGasPlantModalProps) => {
  const { data: brands = [], isLoading: brandsLoading } = useLPGBrands();
  const createPlant = useCreateGasPlant();
  const updatePlant = useUpdateGasPlant();
  const createOfficer = useCreateAreaOfficer();
  const updateOfficer = useUpdateAreaOfficer();

  const [form, setForm] = useState(EMPTY_FORM);

  // Populate form when editing
  useEffect(() => {
    if (editingPlant) {
      setForm({
        plant_name:     editingPlant.plant_name,
        brand_id:       editingPlant.brand_id ?? '',
        location:       editingPlant.location ?? '',
        officer_name:   editingPlant.officer_name ?? '',
        whatsapp_phone: editingPlant.whatsapp_phone ?? '',
        email:          editingPlant.email ?? '',
      });
    } else {
      setForm(EMPTY_FORM);
    }
  }, [editingPlant, open]);

  const isPending =
    createPlant.isPending ||
    updatePlant.isPending ||
    createOfficer.isPending ||
    updateOfficer.isPending;

  const isEditing = !!editingPlant;
  const isOfficerRequired = !!editingPlant?.officer_id;

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    const plantPayload = {
      plant_name: form.plant_name.trim(),
      brand_id:   form.brand_id || null,
      location:   form.location.trim() || undefined,
    };

    const officerPayload = {
      officer_name:    form.officer_name.trim(),
      whatsapp_phone:  form.whatsapp_phone.trim() || undefined,
      email:           form.email.trim() || undefined,
    };

    try {
      if (isEditing) {
        // 1. Update plant details
        await updatePlant.mutateAsync({ plant_id: editingPlant!.plant_id, ...plantPayload });

        // 2. Update or create Area Officer
        if (editingPlant!.officer_id) {
          if (officerPayload.officer_name) {
            await updateOfficer.mutateAsync({
              officer_id: editingPlant!.officer_id,
              ...officerPayload,
            });
          }
        } else {
          if (officerPayload.officer_name) {
            await createOfficer.mutateAsync({
              plant_id: editingPlant!.plant_id,
              ...officerPayload,
            });
          }
        }
      } else {
        // 1. Create plant
        const newPlant = (await createPlant.mutateAsync(plantPayload)) as { plant_id: string };

        // 2. Create Area Officer if name is provided
        if (officerPayload.officer_name && newPlant?.plant_id) {
          await createOfficer.mutateAsync({
            plant_id: newPlant.plant_id,
            ...officerPayload,
          });
        }
      }
      handleClose();
    } catch (error) {
      console.error('Error saving gas plant or area officer:', error);
    }
  };

  const handleClose = () => {
    setForm(EMPTY_FORM);
    createPlant.reset();
    updatePlant.reset();
    createOfficer.reset();
    updateOfficer.reset();
    onClose();
  };

  if (!open) return null;

  const activeError =
    createPlant.error ||
    updatePlant.error ||
    createOfficer.error ||
    updateOfficer.error;

  return (
    <div className="modal-overlay" onClick={handleClose}>
      <div
        className="modal-content glass-panel"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={isEditing ? 'Edit Gas Plant' : 'Add Gas Plant'}
        style={{ maxWidth: '520px' }}
      >
        {/* Header */}
        <div className="modal-header">
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            <div className="modal-icon" style={{ background: 'rgba(59,130,246,0.12)', color: 'var(--primary)' }}>
              <Factory size={18} />
            </div>
            <div>
              <h2 className="modal-title">{isEditing ? 'Edit Gas Plant' : 'Add Gas Plant'}</h2>
              <p className="modal-subtitle">
                {isEditing ? 'Update plant details' : 'Register a new LPG filling plant'}
              </p>
            </div>
          </div>
          <button className="modal-close" onClick={handleClose} aria-label="Close">
            <X size={18} />
          </button>
        </div>

        <form onSubmit={handleSubmit}>
          <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: '1.1rem' }}>

            {/* Plant Name */}
            <div className="input-group">
              <label className="input-label" htmlFor="gp-plant-name">
                Plant Name <span style={{ color: 'var(--danger)' }}>*</span>
              </label>
              <input
                id="gp-plant-name"
                type="text"
                className="input-field"
                placeholder="e.g. Dhaka North Filling Plant"
                value={form.plant_name}
                onChange={(e) => setForm((p) => ({ ...p, plant_name: e.target.value }))}
                required
                autoFocus
              />
            </div>

            {/* Company / Brand */}
            <div className="input-group">
              <label className="input-label" htmlFor="gp-brand">
                Company Name
              </label>
              <select
                id="gp-brand"
                className="input-field"
                value={form.brand_id}
                onChange={(e) => setForm((p) => ({ ...p, brand_id: e.target.value }))}
              >
                <option value="">
                  {brandsLoading ? 'Loading companies…' : '— Select Company —'}
                </option>
                {brands
                  .filter((b) => b.is_active)
                  .map((b) => (
                    <option key={b.brand_id} value={b.brand_id}>
                      {b.brand_name}
                    </option>
                  ))}
              </select>
              {brands.filter((b) => b.is_active).length === 0 && !brandsLoading && (
                <p style={{ fontSize: '0.75rem', color: 'var(--text-muted)', marginTop: '0.35rem' }}>
                  No active brands found. Add brands in Settings → LPG Brands first.
                </p>
              )}
            </div>

            {/* Location */}
            <div className="input-group">
              <label className="input-label" htmlFor="gp-location">
                Location / Address
              </label>
              <textarea
                id="gp-location"
                className="input-field"
                placeholder="e.g. Mirpur DOHS, Dhaka-1216"
                value={form.location}
                onChange={(e) => setForm((p) => ({ ...p, location: e.target.value }))}
                rows={3}
                style={{ resize: 'vertical', minHeight: '80px' }}
              />
            </div>

            {/* Divider */}
            <div style={{ borderTop: '1px solid var(--border-color)', margin: '0.5rem 0' }} />

            {/* Area Officer Section Header */}
            <div>
              <h3 style={{ fontSize: '0.95rem', fontWeight: 600, color: 'var(--text-main)', marginBottom: '0.25rem' }}>
                Area Officer Details
              </h3>
              <p style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>
                {isOfficerRequired
                  ? 'Update assigned Area Officer details'
                  : 'Optional — provide details to assign an area officer to this plant.'}
              </p>
            </div>

            {/* Officer Name */}
            <div className="input-group">
              <label className="input-label" htmlFor="gp-officer-name">
                Officer Name {isOfficerRequired && <span style={{ color: 'var(--danger)' }}>*</span>}
              </label>
              <input
                id="gp-officer-name"
                type="text"
                className="input-field"
                placeholder="e.g. Md. Rahim Uddin"
                value={form.officer_name}
                onChange={(e) => setForm((p) => ({ ...p, officer_name: e.target.value }))}
                required={isOfficerRequired}
              />
            </div>

            {/* WhatsApp Phone */}
            <div className="input-group">
              <label className="input-label" htmlFor="gp-whatsapp-phone">
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.4rem' }}>
                  <Phone size={13} /> WhatsApp Phone
                </span>
              </label>
              <input
                id="gp-whatsapp-phone"
                type="tel"
                className="input-field"
                placeholder="e.g. +880 1712 345678"
                value={form.whatsapp_phone}
                onChange={(e) => setForm((p) => ({ ...p, whatsapp_phone: e.target.value }))}
              />
            </div>

            {/* Email */}
            <div className="input-group" style={{ marginBottom: 0 }}>
              <label className="input-label" htmlFor="gp-email">
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.4rem' }}>
                  <Mail size={13} /> Email
                </span>
              </label>
              <input
                id="gp-email"
                type="email"
                className="input-field"
                placeholder="e.g. officer@company.com"
                value={form.email}
                onChange={(e) => setForm((p) => ({ ...p, email: e.target.value }))}
              />
            </div>

          </div>

          {/* Footer */}
          <div className="modal-footer">
            <button type="button" className="btn btn-ghost" onClick={handleClose}>
              Cancel
            </button>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={isPending || !form.plant_name.trim()}
            >
              {isPending ? (
                <><Loader2 size={15} className="spin" /> Saving…</>
              ) : isEditing ? 'Update Plant' : 'Add Plant'}
            </button>
          </div>

          {activeError && (
            <div className="auth-error" style={{ margin: '0 1.5rem 1.5rem' }}>
              {(activeError as Error).message}
            </div>
          )}
        </form>
      </div>
    </div>
  );
};
