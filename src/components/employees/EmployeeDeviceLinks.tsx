import { useState } from 'react';
import { Fingerprint, Link2, Unlink } from 'lucide-react';
import { useAttendanceConfiguration } from '../../hooks/useAttendance';
import { PurchaseSelect } from '../purchases/PurchaseControls';
import type { AttendanceLink } from '../../types/attendance';
import type { EmployeeInput } from '../../types/employee';

export function EmployeeDeviceLinks({ links, changes, onChange }: { links: AttendanceLink[]; changes: NonNullable<EmployeeInput['attendance_links']>; onChange: (value: NonNullable<EmployeeInput['attendance_links']>) => void }) {
 const config = useAttendanceConfiguration();
 const [editing, setEditing] = useState(false); const [device, setDevice] = useState(''); const [pin, setPin] = useState('');
 const current = links.filter(link => !link.unlinked_at);
 const staged = [...current.map(link => ({ device_id: link.device_id, pin: link.pin, name: link.device_name })), ...changes.filter(change => !current.some(link => link.device_id === change.device_id)).map(change => ({ ...change, name: config.data?.devices.find(d => d.device_id === change.device_id)?.name ?? 'Device' }))]
  .map(link => ({ ...link, pin: changes.find(change => change.device_id === link.device_id)?.pin === undefined ? link.pin : changes.find(change => change.device_id === link.device_id)?.pin })).filter(link => !!link.pin);
 function change(id: string, value: string | null) {
  const expected = current.find(link => link.device_id === id)?.link_id ?? null;
  onChange([...changes.filter(entry => entry.device_id !== id), { device_id: id, pin: value, expected }]);
 }
 return <section className="employee-terms-editor employee-device-editor" aria-label="Employee device linking">
  <div className="employee-section-heading"><h3><Fingerprint size={15} aria-hidden="true" />Attendance device</h3>{!editing && !staged.length && <button className="btn btn-ghost" type="button" onClick={() => setEditing(true)}><Link2 size={14} />Link device</button>}</div>
  {config.isPending && <p role="status">Loading devices…</p>}{config.isError && <p role="alert">Devices unavailable. <button type="button" className="btn btn-ghost" onClick={() => void config.refetch()}>Retry</button></p>}
  {staged.map(link => <div className="employee-section-heading" key={link.device_id}><span>{link.name} · User ID <strong>{link.pin}</strong></span><button className="btn btn-secondary" type="button" onClick={() => change(link.device_id, null)}><Unlink size={13} />Unlink</button></div>)}
  {!staged.length && <p className="employee-hint">No linked device.</p>}
  {editing && <div className="attendance-form"><PurchaseSelect label="Attendance device" value={device} onChange={setDevice} options={[{ value: '', label: 'Select device' }, ...(config.data?.devices ?? []).filter(d => d.enabled && d.approved && !staged.some(link => link.device_id === d.device_id)).map(d => ({ value: d.device_id, label: d.name }))]} />
   <label className="input-group"><span className="input-label">Machine User ID</span><input className="input-field" maxLength={24} value={pin} onChange={event => setPin(event.target.value)} /></label>
   <div className="employee-quick-actions"><button type="button" className="btn btn-secondary" onClick={() => setEditing(false)}>Cancel link</button><button type="button" className="btn btn-primary" disabled={!device || !/^[A-Za-z0-9_-]{1,24}$/.test(pin.trim())} onClick={() => { change(device, pin.trim()); setEditing(false); setDevice(''); setPin(''); }}>Link</button></div>
  </div>}
  <p className="employee-hint">Links take effect when the employee is saved. Earlier punches stay unassigned. Unlinking preserves attendance and previous associations.</p>
 </section>;
}
