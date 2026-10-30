import { useState } from 'react';
import { useAuth } from '../../contexts/AuthContext';
import { Plus, Pencil, UserCheck, MapPin, Phone, Mail } from 'lucide-react';
import toast from 'react-hot-toast';
import { useGasPlants, useUpdateGasPlant } from '../../hooks/useGasPlants';
import { useListPage, useGridPageSize } from '../../hooks/useListPage';
import { AddGasPlantModal } from '../gasplants/AddGasPlantModal';
import { AreaOfficerModal } from '../gasplants/AreaOfficerModal';
import { Pagination } from '../ui/Pagination';
import { PurchaseSelect } from '../purchases/PurchaseControls';
import type { GasPlant } from '../../types/gasPlants';
import '../logistics/logistics.css';
export function GasPlantSettings() {
 const { can } = useAuth(); const manage = can('gas_plants:manage');
 const q = useGasPlants(); const update = useUpdateGasPlant(); const [search, setSearch] = useState(''); const [status, setStatus] = useState('all');
 const [adding, setAdding] = useState(false); const [edit, setEdit] = useState<GasPlant | null>(null); const [officer, setOfficer] = useState<GasPlant | null>(null);
 const { grid, pageSize } = useGridPageSize(); const plants = (q.data ?? []).filter(p => (status === 'all' || p.is_active === (status === 'active')) && [p.plant_name, p.brand_name, p.location, p.officer_name].join(' ').toLowerCase().includes(search.toLowerCase()));
 const paging = useListPage(plants, pageSize, search + status);
 async function toggle(p: GasPlant) { try { await update.mutateAsync({ plant_id: p.plant_id, is_active: !p.is_active }); } catch (e) { toast.error(e instanceof Error ? e.message : 'Plant could not be updated'); } }
 return <section className="settings-section gas-plant-settings"><header className="settings-section-heading"><div><h2>Gas plants</h2><p>Filling destinations, company brands and area officer contacts.</p></div>{manage && <button className="btn btn-primary" onClick={() => { setEdit(null); setAdding(true); }}><Plus size={16} />Add gas plant</button>}</header><div className="settings-card logistics-toolbar"><label className="input-group logistics-search"><span className="input-label">Find a gas plant</span><input className="input-field" value={search} onChange={e => setSearch(e.target.value)} placeholder="Plant, brand, location or officer…" /></label><PurchaseSelect label="Status" value={status} onChange={setStatus} options={[{ value: 'all', label: 'All plants' }, { value: 'active', label: 'Active' }, { value: 'inactive', label: 'Inactive' }]} /></div>
 {q.isPending && <p role="status">Loading gas plants…</p>}{q.isError && <p role="alert" className="purchase-error">Gas plants unavailable. <button className="btn btn-secondary" onClick={() => void q.refetch()}>Retry</button></p>}
 {q.data && <><div className="gas-plants-grid adaptive-grid adaptive-grid--plants" ref={grid}>{paging.entries.map(p => <article className="settings-card settings-plant" key={p.plant_id}><div className="purchase-section-heading"><h3>{p.plant_name}</h3><span className={`purchase-badge ${p.is_active ? 'payment-paid' : 'transit-cancelled'}`}>{p.is_active ? 'Active' : 'Inactive'}</span></div><strong>{p.brand_name || 'Brand not assigned'}</strong><p><MapPin size={14} aria-hidden="true" />{p.location || 'Location not saved'}</p><section><span className="input-label">Area officer</span><strong>{p.officer_name || 'Not assigned'}</strong>{p.whatsapp_phone && <a href={`https://wa.me/${p.whatsapp_phone.replace(/[^0-9]/g, '')}`} target="_blank" rel="noreferrer"><Phone size={14} />{p.whatsapp_phone}</a>}{p.email && <a href={`mailto:${p.email}`}><Mail size={14} />{p.email}</a>}</section>{manage && <footer><button className="btn btn-secondary" onClick={() => { setEdit(p); setAdding(true); }}><Pencil size={14} />Edit plant</button><button className="btn btn-ghost" onClick={() => setOfficer(p)}><UserCheck size={14} />Officer</button><button className="btn btn-ghost" disabled={update.isPending} onClick={() => void toggle(p)}>{p.is_active ? 'Deactivate' : 'Activate'}</button></footer>}</article>)}</div>{!paging.total && <p className="empty-state">No gas plants match these filters.</p>}<Pagination {...paging} onChange={paging.setPage} label="gas plants" /></>}
 <AddGasPlantModal open={adding} editingPlant={edit} onClose={() => { setAdding(false); setEdit(null); }} /><AreaOfficerModal open={!!officer} plant={officer} onClose={() => setOfficer(null)} /></section>;
}
