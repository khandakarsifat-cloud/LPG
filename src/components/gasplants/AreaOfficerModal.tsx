import { useState } from 'react';
import toast from 'react-hot-toast';
import { useCreateAreaOfficer, useUpdateAreaOfficer } from '../../hooks/useGasPlants';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import type { GasPlant } from '../../types/gasPlants';
export function AreaOfficerModal({ open, onClose, plant }: { open: boolean; onClose: () => void; plant: GasPlant | null }) {
 return open && plant ? <OfficerForm plant={plant} onClose={onClose} /> : null;
}
function OfficerForm({ plant, onClose }: { plant: GasPlant; onClose: () => void }) {
 const create = useCreateAreaOfficer(); const update = useUpdateAreaOfficer(); const busy = create.isPending || update.isPending;
 const [draft, setDraft] = useState({ officer_name: plant.officer_name ?? '', whatsapp_phone: plant.whatsapp_phone ?? '', email: plant.email ?? '' }); const [error, setError] = useState<string | null>(null);
 async function save() { try { const payload = { ...draft, officer_name: draft.officer_name.trim() }; if (plant.officer_id) await update.mutateAsync({ ...payload, officer_id: plant.officer_id }); else await create.mutateAsync({ ...payload, plant_id: plant.plant_id }); toast.success('Officer saved'); onClose(); } catch (e) { setError(e instanceof Error ? e.message : 'Officer could not be saved.'); } }
 return <PurchaseDialog title={plant.officer_id ? 'Edit area officer' : 'Assign area officer'} subtitle={plant.plant_name} onClose={onClose} busy={busy} compact><form onSubmit={e => { e.preventDefault(); void save(); }}><div className="modal-body"><fieldset className="vehicle-form-fields" disabled={busy}>{(['officer_name', 'whatsapp_phone', 'email'] as const).map((key, i) => <label className="input-group" key={key}><span className="input-label">{['Officer name *', 'WhatsApp phone', 'Email'][i]}</span><input className="input-field" type={key === 'email' ? 'email' : key === 'whatsapp_phone' ? 'tel' : 'text'} required={key === 'officer_name'} maxLength={key === 'officer_name' ? 100 : key === 'email' ? 255 : 30} value={draft[key]} onChange={e => setDraft({ ...draft, [key]: e.target.value })} /></label>)}</fieldset>{error && <p className="purchase-error" role="alert">{error}</p>}</div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>Back</button><button className="btn btn-primary" disabled={busy || !draft.officer_name.trim()}>{busy ? 'Saving…' : 'Save officer'}</button></div></form></PurchaseDialog>;
}
