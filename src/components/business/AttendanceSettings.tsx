import { useState } from 'react';
import { Plus, Pencil, Fingerprint, ShieldCheck } from 'lucide-react';
import { useAttendanceConfiguration, useAttendanceOperation, useAttendanceUsers } from '../../hooks/useAttendance';
import { attendanceConnection } from '../../lib/attendance';
import type { AttendanceConfiguration, AttendanceDevice, DeviceAction } from '../../types/attendance';
import { PurchaseConfirmation, PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { TimezoneSelect } from './TimezoneSelect';
import '../employees/employees.css';
import '../employees/attendance.css';

export function AttendanceSettings() {
 const query = useAttendanceConfiguration(); const [register, setRegister] = useState(false);
 return <section className="settings-section attendance-settings" aria-label="Attendance settings">
  <header className="settings-section-heading"><div><h2>Attendance</h2><p>Workday rules and connected devices. Attendance does not change salary or payroll.</p></div></header>
  {query.isPending && <p role="status">Loading attendance settings…</p>}{query.isError && <p role="alert" className="purchase-error">Settings unavailable. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
  {query.data && <><AttendanceRules key={query.data.timezone + query.data.next_clock_out_cutoff} config={query.data} />
   <div className="settings-card"><div className="settings-section-heading"><div><h3>Attendance devices</h3><p>Devices connect directly over HTTPS ADMS. No fixed public IP is needed.</p></div><button className="btn btn-secondary" onClick={() => setRegister(true)}><Plus size={14} />Register device</button></div>
    <div className="attendance-device-list">{query.data.devices.map(device => <DeviceCard key={device.device_id} device={device} />)}</div>
    {!query.data.devices.length && <p className="employee-empty">Register your first attendance device to get started.</p>}
   </div>
  </>}
  {register && <DeviceForm onClose={() => setRegister(false)} />}
 </section>;
}

function AttendanceRules({ config }: { config: AttendanceConfiguration }) {
 const [zone, setZone] = useState(config.timezone); const [departure, setDeparture] = useState(config.next_clock_out_cutoff.slice(0, 5)); const operation = useAttendanceOperation();
 return <form className="settings-card attendance-rules" onSubmit={event => { event.preventDefault(); operation.mutate({ action: 'settings', timezone: zone, clock_out_cutoff: departure }); }}>
  <div className="settings-section-heading"><div><h3>Workday rules</h3><p>Use the same local clock on your terminal.</p></div></div>
  <fieldset className="employee-fields attendance-rules-fields" disabled={operation.isPending}><TimezoneSelect value={zone} onChange={setZone} />
   <div className="attendance-cutoff-field"><label className="input-group"><span className="input-label">Clock-out cutoff</span><input className="input-field" required type="time" min="00:01" max="23:59" value={departure} onChange={event => setDeparture(event.target.value)} /></label><p className="employee-hint">Before this time: keep the earliest clock-in. At or after it: keep the latest clock-out. Extra punches update the same daily record. Missing punches stay missing.</p>
   <p className="employee-hint">Attendance follows calendar dates, from 12:00 AM to the next midnight in your business timezone. There is no adjustable day boundary.</p>
   <p className="employee-hint">Current clock-out cutoff: {config.clock_out_cutoff.slice(0, 5)}. Saved changes start tomorrow; earlier dates keep their cutoff.</p></div>
  </fieldset>
  <div className="settings-save-row"><button className="btn btn-primary" disabled={operation.isPending || !departure || departure === '00:00' || (zone === config.timezone && departure === config.next_clock_out_cutoff.slice(0, 5))}>{operation.isPending ? 'Saving…' : 'Save attendance rules'}</button>{operation.isSuccess && <span role="status">Attendance rules saved.</span>}</div>
  {operation.isError && <p className="purchase-error" role="alert">{operation.error.message}</p>}
 </form>;
}

function DeviceCard({ device }: { device: AttendanceDevice }) {
 const [edit, setEdit] = useState(false); const [users, setUsers] = useState(false); const [action, setAction] = useState<DeviceAction | null>(null); const operation = useAttendanceOperation();
 const actionLabels: Record<DeviceAction, string> = { register: 'Register device', edit: 'Edit device', approve: 'Approve device', disable: 'Disable device', enable: 'Enable device', remove: 'Remove device' };
 const perform = () => { if (action) operation.mutate({ action: 'device', device_id: device.device_id, serial: device.serial, name: device.name, operation: action }, { onSuccess: () => setAction(null) }); };
 return <article className="attendance-device"><div className="attendance-device-identity"><span className="attendance-device-icon"><Fingerprint size={18} aria-hidden="true" /></span><div><strong>{device.name}</strong><small>Serial {device.serial}</small></div><span className="employee-status-badge">{attendanceConnection(device)}</span></div>
  <dl className="attendance-device-facts"><div><dt>Last seen</dt><dd>{device.last_seen_at ? new Date(device.last_seen_at).toLocaleString() : 'Never'}</dd></div><div><dt>Last accepted upload</dt><dd>{device.last_upload_at ? new Date(device.last_upload_at).toLocaleString() : 'Never'}</dd></div></dl>
  {device.last_ignored_count > 0 && <p className="employee-hint" role="status">Earlier punches skipped in the last upload: {device.last_ignored_count}. They predate this registration and were not added to this business.</p>}
  <div className="employee-quick-actions"><button className="btn btn-secondary" onClick={() => setEdit(true)}><Pencil size={13} />Edit device</button>{!device.approved && <button className="btn btn-primary" onClick={() => setAction('approve')}><ShieldCheck size={14} />Approve</button>}{device.approved && <button className="btn btn-secondary" onClick={() => setAction(device.enabled ? 'disable' : 'enable')}>{device.enabled ? 'Disable' : 'Enable'}</button>}<button className="btn btn-ghost" onClick={() => setUsers(true)}>Unlinked users · {device.unmapped}</button></div>

  {edit && <DeviceForm device={device} onClose={() => setEdit(false)} onAction={value => { setEdit(false); setAction(value); }} />}
  {users && <DeviceUsers device={device} onClose={() => setUsers(false)} />}

  {action && <PurchaseConfirmation title={actionLabels[action]} action={actionLabels[action]} busy={operation.isPending} onCancel={() => setAction(null)} onConfirm={perform}><p>{action === 'remove' ? 'End all current employee links and release this serial for a new registration. Saved attendance, past associations and raw machine records stay with this business.' : action === 'approve' ? 'Authorize this device serial to upload attendance to this business. Serial identification alone does not prevent impersonation.' : `${action === 'disable' ? 'Stop' : 'Allow'} attendance uploads for this device.`}</p>{action === 'remove' && <p>Before removing, reconnect the machine and check that its pending punches have arrived. Unsent old punches cannot be recovered through the new registration. Registering it again requires approval and fresh employee links.</p>}<strong>{device.name}</strong>{operation.isError && <p className="purchase-error" role="alert">{operation.error.message}</p>}</PurchaseConfirmation>}
 </article>;
}

function DeviceForm({ device, onClose, onAction }: { device?: AttendanceDevice; onClose: () => void; onAction?: (action: DeviceAction) => void }) {
 const [serial, setSerial] = useState(device?.serial ?? ''); const [name, setName] = useState(device?.name ?? 'Shop MB20-VL'); const operation = useAttendanceOperation();
 return <PurchaseDialog title={device ? 'Edit attendance device' : 'Register attendance device'} onClose={onClose} busy={operation.isPending} compact>
  <form onSubmit={event => { event.preventDefault(); operation.mutate({ action: 'device', device_id: device?.device_id ?? null, serial, name, operation: device ? 'edit' : 'register' }, { onSuccess: onClose }); }}>
   <div className="modal-body attendance-form"><label>Device name<input className="input-field" required maxLength={80} value={name} onChange={event => setName(event.target.value)} /></label><label>Serial number<input className="input-field" required disabled={!!device} pattern="[A-Za-z0-9_-]{1,40}" maxLength={40} value={serial} onChange={event => setSerial(event.target.value)} /></label><p className="employee-hint">No shop public IP is needed. Set the terminal to ADMS with HTTPS and server api.lpg.144.79.249.4.sslip.io:443. Serial numbers identify registered devices but do not provide secure authentication.</p>{!device && <><p className="employee-hint">If this machine belongs to another business, remove it there first. This registration starts fresh: approve the device, then link each employee to their machine User ID.</p><p className="employee-hint">Earlier machine logs are skipped. Check the machine clock and timezone before use. Fingerprints and users stored on the physical machine are not erased by this system.</p></>}{operation.isError && <p className="purchase-error" role="alert">{operation.error.message}</p>}
    {device && <div className="employee-quick-actions"><button type="button" className="btn btn-ghost" onClick={() => onAction?.('remove')}>Remove device</button></div>}
   </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={operation.isPending}>{operation.isPending ? 'Saving…' : device ? 'Save device' : 'Register device'}</button></div>
  </form>
 </PurchaseDialog>;
}

function DeviceUsers({ device, onClose }: { device: AttendanceDevice; onClose: () => void }) {
 const [page, setPage] = useState(0); const query = useAttendanceUsers(device.device_id, page);
 return <PurchaseDialog title="Unlinked machine users" subtitle={device.name} onClose={onClose} compact><div className="modal-body attendance-form"><p className="employee-hint">Use Add employee or Edit employee to link a machine User ID. Only punches within an effective employee link count toward attendance; earlier unassigned punches are not adopted.</p>{query.isPending && <p role="status">Loading users…</p>}{query.isError && <p role="alert" className="purchase-error">Users unavailable. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}{query.data?.entries.map(user => <div className="settings-catalog-row" key={user.pin}><strong>User ID {user.pin}</strong><small>Last received {new Date(user.last_seen_at).toLocaleString()}</small></div>)}{query.data && !query.data.entries.length && <p>No unlinked users.</p>}<Pagination page={page} pageSize={25} total={query.data?.total ?? 0} onChange={setPage} label="machine users" busy={query.isFetching} /></div><div className="modal-footer"><button className="btn btn-secondary" onClick={onClose}>Close</button></div></PurchaseDialog>;
}
