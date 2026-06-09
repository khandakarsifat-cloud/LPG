import { useState, type FormEvent, useEffect } from 'react';
import { X, UserCheck, Loader2, Phone, Mail } from 'lucide-react';
import { useCreateAreaOfficer, useUpdateAreaOfficer } from '../../hooks/useGasPlants';
import type { GasPlant } from '../../types/gasPlants';

interface AreaOfficerModalProps {
  open:   boolean;
  onClose: () => void;
  plant:  GasPlant | null;
}

const EMPTY_FORM = { officer_name: '', whatsapp_phone: '', email: '' };

export const AreaOfficerModal = ({ open, onClose, plant }: AreaOfficerModalProps) => {
  const createOfficer = useCreateAreaOfficer();
  const updateOfficer = useUpdateAreaOfficer();

  const [form, setForm] = useState(EMPTY_FORM);

  const hasOfficer = !!plant?.officer_id;
  const isPending  = createOfficer.isPending || updateOfficer.isPending;

  // Pre-fill if officer exists
  useEffect(() => {
    if (plant && plant.officer_id) {
      setForm({
        officer_name:   plant.officer_name   ?? '',
        whatsapp_phone: plant.whatsapp_phone ?? '',
        email:          plant.email          ?? '',
      });
    } else {
      setForm(EMPTY_FORM);
    }
  }, [plant, open]);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!plant) return;

    const payload = {
      officer_name:   form.officer_name.trim(),
      whatsapp_phone: form.whatsapp_phone.trim() || undefined,
      email:          form.email.trim()          || undefined,
    };

    if (hasOfficer) {
      await updateOfficer.mutateAsync({ officer_id: plant.officer_id!, ...payload });
    } else {
      await createOfficer.mutateAsync({ plant_id: plant.plant_id, ...payload });
    }
    handleClose();
  };

  const handleClose = () => {
    setForm(EMPTY_FORM);
    createOfficer.reset();
    updateOfficer.reset();
    onClose();
  };

  if (!open || !plant) return null;

  const activeError = createOfficer.error || updateOfficer.error;

  return (
    <div className="modal-overlay" onClick={handleClose}>
      <div
        className="modal-content glass-panel"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label="Area Officer"
        style={{ maxWidth: '460px' }}
      >
        {/* Header */}
        <div className="modal-header">
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            <div className="modal-icon" style={{ background: 'rgba(16,185,129,0.12)', color: 'var(--accent)' }}>
              <UserCheck size={18} />
            </div>
            <div>
              <h2 className="modal-title">{hasOfficer ? 'Edit Area Officer' : 'Assign Area Officer'}</h2>
              <p className="modal-subtitle" style={{ maxWidth: '280px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {plant.plant_name}
              </p>
            </div>
          </div>
          <button className="modal-close" onClick={handleClose} aria-label="Close">
            <X size={18} />
          </button>
        </div>

        <form onSubmit={handleSubmit}>
          <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: '1.1rem' }}>

            {/* Officer Name */}
            <div className="input-group">
              <label className="input-label" htmlFor="ao-name">
                Officer Name <span style={{ color: 'var(--danger)' }}>*</span>
              </label>
              <input
                id="ao-name"
                type="text"
                className="input-field"
                placeholder="e.g. Md. Rahim Uddin"
                value={form.officer_name}
                onChange={(e) => setForm((p) => ({ ...p, officer_name: e.target.value }))}
                required
                autoFocus
              />
            </div>

            {/* WhatsApp Phone */}
            <div className="input-group">
              <label className="input-label" htmlFor="ao-phone">
                <span style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
                  <Phone size={13} /> WhatsApp Phone
                </span>
              </label>
              <input
                id="ao-phone"
                type="tel"
                className="input-field"
                placeholder="e.g. +880 1712 345678"
                value={form.whatsapp_phone}
                onChange={(e) => setForm((p) => ({ ...p, whatsapp_phone: e.target.value }))}
              />
            </div>

            {/* Email */}
            <div className="input-group" style={{ marginBottom: 0 }}>
              <label className="input-label" htmlFor="ao-email">
                <span style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
                  <Mail size={13} /> Email
                </span>
              </label>
              <input
                id="ao-email"
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
              style={{ background: 'var(--accent)', boxShadow: '0 2px 10px rgba(16,185,129,0.3)' }}
              disabled={isPending || !form.officer_name.trim()}
            >
              {isPending ? (
                <><Loader2 size={15} className="spin" /> Saving…</>
              ) : hasOfficer ? 'Update Officer' : 'Assign Officer'}
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
