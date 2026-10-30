import { useState, type FormEvent } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { PurchaseConfirmation, PurchaseDialog, PurchaseNumber, PurchaseSelect } from '../purchases/PurchaseControls';
import { DatePicker } from '../ui/DatePicker';
import { normalizePhoneInput, validateBDMobilePhone, BD_MOBILE_PHONE_ERROR } from '../../lib/bdPhone';
import { employeeDate, employeeToday, employeeUnitLabels } from '../../lib/employee';
import { formatBDT } from '../../lib/formatBDT';
import type { EmployeeInput, EmployeeProfile, BusinessUnit } from '../../types/employee';
import type { useEmployeeOperation } from '../../hooks/useEmployees';
import { useEmployeeAttendance } from '../../hooks/useAttendance';
import { useBusinessCatalogs } from '../../hooks/useBusinessSettings';
import { EmployeeDeviceLinks } from './EmployeeDeviceLinks';

export type EmployeeOperationHandle = ReturnType<typeof useEmployeeOperation>;
export function EmployeeOperationNotice({ operation, onRecovered }: { operation: EmployeeOperationHandle; onRecovered?: () => void }) {
 return <>{operation.hasPending && <p className="purchase-alert" role="status">A saved request needs confirmation. Recover it before another change. <button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={async () => { try { await operation.mutateAsync(undefined); toast.success('Saved request confirmed', { position: 'bottom-center' }); onRecovered?.(); } catch { /* retained below */ } }}>Recover request</button></p>}{operation.error && <p className="purchase-error" role="alert">{operation.error.message}</p>}</>;
}
export function EmployeeForm({ profile, types, operation, onClose, inline = false }: { inline?: boolean; profile?: EmployeeProfile; types: string[]; operation: EmployeeOperationHandle; onClose: () => void }) {
 const e = profile?.employee; const latest = profile?.terms[0];
 const catalogs = useBusinessCatalogs();
 const attendance = useEmployeeAttendance(e?.employee_id ?? '', employeeToday().slice(0, 7));
 const [linkChanges, setLinkChanges] = useState<NonNullable<EmployeeInput['attendance_links']>>([]);
 const [form, setForm] = useState<EmployeeInput>({ employee_id: e?.employee_id, revision: e?.revision, name: e?.name ?? '', address: e?.address ?? '', notes: e?.notes ?? '', employee_type_name: e?.employee_type_name ?? 'General Staff', business_unit: e?.business_unit ?? 'gas_business', phones: e?.phones.map(p => ({ ...p })) ?? [{ phone: '', is_primary: true }] });
 const [changeTerms, setChangeTerms] = useState(!e); const [salary, setSalary] = useState(latest?.monthly_salary ?? 0);
 const [active, setActive] = useState(latest?.is_active ?? true); const [date, setDate] = useState(e ? latest && latest.effective_from > employeeToday() ? latest.effective_from : employeeToday() : employeeToday()); const [reason, setReason] = useState(''); const [error, setError] = useState('');
 const [confirming, setConfirming] = useState(false);
 const busy = operation.isPending; const disabled = busy || operation.hasPending;
 const roleOptions = catalogs.data ? catalogs.data.roles.filter(role => role.active || role.name === e?.employee_type_name).map(role => role.name) : types;

 const changes: { label: string; before: string; after: string }[] = [];
 const compare = (label: string, before: string, after: string) => { if (before !== after) changes.push({ label, before: before || 'None', after: after || 'None' }); };
 if (e) {
  compare('Name', e.name, form.name.trim()); compare('Role', e.employee_type_name ?? '', form.employee_type_name.trim());
  compare('Business unit', employeeUnitLabels[e.business_unit], employeeUnitLabels[form.business_unit]);
  compare('Address', e.address ?? '', form.address.trim()); compare('Notes', e.notes ?? '', form.notes.trim());
  const phoneLabel = (phones: EmployeeInput['phones']) => phones.map(p => `${p.phone}${p.is_primary ? ' (primary)' : ''}`).join(', ');
  compare('Phone numbers', phoneLabel(e.phones), phoneLabel(form.phones));
  linkChanges.forEach(link => compare(`Device · ${attendance.data?.links.find(old => old.device_id === link.device_id)?.device_name ?? 'New link'}`, attendance.data?.links.find(old => old.device_id === link.device_id && !old.unlinked_at)?.pin ?? '', link.pin ?? ''));
 }
 async function save() {
  if (disabled) return;
  try { await operation.mutateAsync({ action: 'profile', profile: { ...form, attendance_links: linkChanges, ...(changeTerms ? { terms: { monthly_salary: salary, effective_from: date, is_active: active, reason: reason.trim() || 'Initial employment terms' } } : {}) } }); toast.success(e ? 'Employee updated' : 'Employee added', { position: 'bottom-center' }); onClose(); } catch { /* recoverable notice */ }
 }
 function submit(event: FormEvent) {
  event.preventDefault(); setError('');
  if (disabled) return;
  if (!form.phones.every(p => validateBDMobilePhone(p.phone))) { setError(BD_MOBILE_PHONE_ERROR); return; }
  if (changeTerms && e && !reason.trim()) { setError('Describe the salary or employment change.'); return; }
  if (e) { if (!changes.length && !changeTerms) { setError('No employee details have changed.'); return; } setConfirming(true); } else void save();
 }
 const content = <>
  {confirming && <PurchaseConfirmation title="Confirm employee changes" action="Confirm changes" busy={busy} confirmDisabled={disabled} onCancel={() => setConfirming(false)} onConfirm={() => void save()}>
   <p>Review the changes for <strong>{e?.name}</strong> before saving.</p>
   <dl className="employee-change-list">{changes.map(change => <div key={change.label}><dt>{change.label}</dt><dd><span className="employee-change-before">{change.before}</span><span className="employee-change-after"><span className="employee-change-arrow" aria-label="changes to">&rarr;</span>{change.after}</span></dd></div>)}</dl>
   {changeTerms && <section className="employee-terms-editor"><h3>New salary & employment terms</h3><dl className="employee-confirm-details"><div><dt>Monthly salary</dt><dd>{formatBDT(latest?.monthly_salary ?? 0)} &rarr; <strong>{formatBDT(salary)}</strong></dd></div><div><dt>Status</dt><dd>{latest?.is_active ? 'Active' : 'Inactive'} &rarr; <strong>{active ? 'Active' : 'Inactive'}</strong></dd></div><div><dt>Effective from</dt><dd>{employeeDate(date)}</dd></div><div><dt>Reason</dt><dd>{reason.trim()}</dd></div></dl><p className="employee-hint">Months with saved payments keep their salary amount.</p></section>}
   <EmployeeOperationNotice operation={operation} onRecovered={onClose} />
  </PurchaseConfirmation>}

  <form onSubmit={submit}><div className="modal-body employee-form">
   <fieldset disabled={disabled} className="employee-fields">
    <label className="input-group"><span className="input-label">Employee name</span><input required maxLength={255} className="input-field" value={form.name} onChange={ev => setForm({ ...form, name: ev.target.value })} /></label>
    <div className="employee-form-grid"><PurchaseSelect label="Employee role" value={form.employee_type_name} options={roleOptions.map(role => ({ value: role, label: role }))} onChange={employee_type_name => setForm({ ...form, employee_type_name })} />
     <PurchaseSelect label="Business unit" value={form.business_unit} options={Object.entries(employeeUnitLabels).map(([value, label]) => ({ value, label }))} onChange={value => setForm({ ...form, business_unit: value as BusinessUnit })} /></div>
    <div className="employee-section-heading"><h3>Phone numbers</h3><button type="button" className="btn btn-ghost" disabled={form.phones.length >= 10} onClick={() => setForm({ ...form, phones: [...form.phones, { phone: '', is_primary: false }] })}><Plus size={14} />Add number</button></div>
    {form.phones.map((phone, i) => <div className="employee-phone-editor" key={i}><input className="input-field" aria-label={`Phone ${i + 1}`} required inputMode="tel" value={phone.phone} onChange={ev => setForm({ ...form, phones: form.phones.map((p, j) => j === i ? { ...p, phone: normalizePhoneInput(ev.target.value) } : p) })} /><label><input type="radio" name="primary-phone" checked={phone.is_primary} onChange={() => setForm({ ...form, phones: form.phones.map((p, j) => ({ ...p, is_primary: i === j })) })} />Primary</label><button type="button" className="btn btn-ghost" aria-label={`Remove phone ${i + 1}`} disabled={form.phones.length === 1} onClick={() => { const phones = form.phones.filter((_, j) => j !== i); if (!phones.some(p => p.is_primary)) phones[0] = { ...phones[0], is_primary: true }; setForm({ ...form, phones }); }}><Trash2 size={15} /></button></div>)}
    <label className="input-group"><span className="input-label">Address</span><input className="input-field" maxLength={1000} value={form.address} onChange={ev => setForm({ ...form, address: ev.target.value })} /></label>
    {e && <label className="employee-check"><input type="checkbox" checked={changeTerms} onChange={ev => setChangeTerms(ev.target.checked)} />Change salary or employment status</label>}
    {changeTerms && <section className="employee-terms-editor"><h3>{e ? 'New salary & employment terms' : 'Starting salary & employment'}</h3><div className="employee-form-grid"><PurchaseNumber label="Monthly salary (Tk)" money value={salary} onChange={value => { setSalary(value ?? 0); if (e) setDate(employeeToday()); }} /><PurchaseSelect label="Employment status" value={active ? 'active' : 'inactive'} options={[{ value: 'active', label: 'Active' }, { value: 'inactive', label: 'Inactive / ended' }]} onChange={value => { setActive(value === 'active'); setDate(employeeToday()); }} /><label className="input-group"><span className="input-label">{e ? 'Effective from' : 'Joining date'}</span><DatePicker label="Salary effective date" value={date} onChange={setDate} /></label></div><p className="employee-hint">The latest active salary for a month applies to the full month. A month with a saved payment keeps its salary amount. Joining and leaving months use the full monthly salary; months with no active employment have no new salary due.</p>{e && <label className="input-group"><span className="input-label">Reason for change</span><input required className="input-field" maxLength={1000} value={reason} onChange={ev => setReason(ev.target.value)} /></label>}</section>}
    <EmployeeDeviceLinks links={attendance.data?.links ?? []} changes={linkChanges} onChange={setLinkChanges} />
    <label className="input-group"><span className="input-label">Notes (optional)</span><textarea className="input-field" rows={2} maxLength={2000} value={form.notes} onChange={ev => setForm({ ...form, notes: ev.target.value })} /></label>
   </fieldset>
   {error && <p role="alert" className="purchase-error">{error}</p>}<EmployeeOperationNotice operation={operation} onRecovered={onClose} />
  </div><div className="modal-footer"><button className="btn btn-secondary" type="button" disabled={busy} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={disabled || !date}>{busy ? 'Saving…' : e ? 'Save changes' : 'Add employee'}</button></div></form>
 </>;
 return inline ? content : <PurchaseDialog title={e ? 'Edit employee' : 'Add employee'} subtitle={e?.name} onClose={onClose} busy={busy} className="employee-dialog">{content}</PurchaseDialog>;
}
