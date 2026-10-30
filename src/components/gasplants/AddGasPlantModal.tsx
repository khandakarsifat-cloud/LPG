import { useState } from 'react';
import toast from 'react-hot-toast';
import { useCreateGasPlant, useUpdateGasPlant } from '../../hooks/useGasPlants';
import { useLPGBrands } from '../../hooks/useBrands';
import { PurchaseDialog, PurchaseSelect } from '../purchases/PurchaseControls';
import type { GasPlant } from '../../types/gasPlants';
export function AddGasPlantModal({ open, onClose, editingPlant }: { open: boolean; onClose: () => void; editingPlant?: GasPlant | null }) {
 return open ? <PlantForm plant={editingPlant} onClose={onClose} /> : null;
}
function PlantForm({ plant, onClose }: { plant?: GasPlant | null; onClose: () => void }) {
 const brands = useLPGBrands(); const create = useCreateGasPlant(); const update = useUpdateGasPlant();
 const [draft, setDraft] = useState({ plant_name: plant?.plant_name ?? '', brand_id: plant?.brand_id ?? '', location: plant?.location ?? '' }); const [error, setError] = useState<string | null>(null);
 const busy = create.isPending || update.isPending;
 async function save() {
  try { const payload = { ...draft, plant_name: draft.plant_name.trim(), brand_id: draft.brand_id || null }; if (plant) await update.mutateAsync({ ...payload, plant_id: plant.plant_id }); else await create.mutateAsync(payload); toast.success('Gas plant saved'); onClose(); }
  catch (e) { setError(e instanceof Error ? e.message : 'Gas plant could not be saved.'); }
 }
 return <PurchaseDialog title={plant ? 'Edit gas plant' : 'Add gas plant'} subtitle="Purchase and transit destination" onClose={onClose} busy={busy} compact><form onSubmit={e => { e.preventDefault(); void save(); }}><div className="modal-body"><fieldset className="vehicle-form-fields" disabled={busy}><label className="input-group"><span className="input-label">Plant name *</span><input className="input-field" required maxLength={100} value={draft.plant_name} onChange={e => setDraft({ ...draft, plant_name: e.target.value })} /></label><PurchaseSelect label="LPG brand" value={draft.brand_id} onChange={v => setDraft({ ...draft, brand_id: v })} options={[{ value: '', label: 'Not assigned' }, ...(brands.data ?? []).map(b => ({ value: b.brand_id, label: b.brand_name }))]} /><label className="input-group"><span className="input-label">Location</span><input maxLength={255} className="input-field" value={draft.location} onChange={e => setDraft({ ...draft, location: e.target.value })} /></label><p className="purchase-hint">Manage area officer contacts from the plant card after saving.</p></fieldset>{error && <p role="alert" className="purchase-error">{error}</p>}{brands.isError && <p role="alert" className="purchase-error">Brands unavailable. <button type="button" className="btn btn-secondary" onClick={() => void brands.refetch()}>Retry</button></p>}</div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>Back</button><button className="btn btn-primary" disabled={busy || !draft.plant_name.trim()}>{busy ? 'Saving…' : 'Save plant'}</button></div></form></PurchaseDialog>;
}
