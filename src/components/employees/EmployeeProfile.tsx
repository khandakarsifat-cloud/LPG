import { useState } from 'react';
import { Pencil, Phone, MapPin, BadgeDollarSign, Gift, ArrowLeft, CalendarDays } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { useEmployeeSalaryMonth, useEmployeeProfile } from '../../hooks/useEmployees';
import { employeeDate, employeeMonth, employeeUnitLabels, employeeStatus } from '../../lib/employee';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { EmployeeForm, type EmployeeOperationHandle } from './EmployeeForm';
import { EmployeePaymentDialog } from './EmployeePayments';
import { EmployeeHistory } from './EmployeeHistory';
import { EmployeeAttendance } from './EmployeeAttendance';
import './employee-profile.css';

export function EmployeeProfileDialog({ id, types, operation, onClose }: { id: string; types: string[]; operation: EmployeeOperationHandle; onClose: () => void }) {
 const { can } = useAuth(); const readable = can('payroll:view') || can('payroll:pay'); const attendance = can('employees:view') || can('employees:manage');
 const query = useEmployeeProfile(id); const e = query.data?.employee;
 const [view, setView] = useState<'profile' | 'edit' | 'salary' | 'bonus'>('profile'); const [period, setPeriod] = useState(employeeMonth());
 const disabled = operation.isPending || operation.hasPending;
 return <PurchaseDialog title={view === 'profile' ? 'Employee profile' : view === 'edit' ? 'Edit employee' : view === 'salary' ? 'Pay salary' : 'Give bonus'} subtitle={view === 'profile' ? undefined : e?.name} onClose={onClose} busy={operation.isPending} className="employee-profile-dialog">
  {view !== 'profile' && <div className="employee-profile-back"><button className="btn btn-ghost" disabled={operation.isPending} onClick={() => setView('profile')}><ArrowLeft size={15} />Profile</button></div>}
  {query.isPending && <p className="modal-body" role="status">Loading employee…</p>}{query.error && <p role="alert" className="modal-body purchase-error">Employee could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
  {e && query.data && (view === 'edit' ? <EmployeeForm inline profile={query.data} types={types} operation={operation} onClose={() => setView('profile')} /> : view === 'salary' || view === 'bonus' ? <EmployeePaymentDialog inline employee={e} period={period} kind={view} operation={operation} onClose={() => setView('profile')} /> : <div className="modal-body employee-profile-body">
   <section className="employee-panel employee-profile-identity" aria-label="Employee details">
    <div className="employee-identity"><span className="employee-avatar" aria-hidden="true">{e.name.slice(0, 1).toUpperCase()}</span><div><h3>{e.name}</h3><p>{e.employee_type_name || 'Employee'} · {employeeUnitLabels[e.business_unit]}</p></div><span className={`employee-status-badge ${e.is_active ? 'active' : 'inactive'}`}>{employeeStatus(e)}</span>{can('employees:edit') && <button className="btn btn-secondary" onClick={() => setView('edit')} disabled={disabled}><Pencil size={14} />Edit</button>}</div>
    <div className="employee-profile-facts">{e.phones.map(phone => <a key={phone.phone} href={`tel:${phone.phone}`}><Phone size={13} aria-hidden="true" />{phone.phone}</a>)}{e.address && <span><MapPin size={13} aria-hidden="true" />{e.address}</span>}<span><CalendarDays size={13} aria-hidden="true" />Joined {employeeDate(e.joining_date)}</span></div>
    {e.notes && <p className="employee-profile-note">{e.notes}</p>}
    <div className="employee-profile-actions"><div className="employee-profile-rate"><span>Monthly rate</span><strong>{formatBDT(e.current_salary)}</strong></div>{can('payroll:pay') && <div className="employee-quick-actions"><button className="btn btn-primary" disabled={disabled} onClick={() => setView('salary')}><BadgeDollarSign size={16} />Pay salary</button><button className="btn btn-secondary" disabled={disabled} onClick={() => setView('bonus')}><Gift size={16} />Give bonus</button></div>}</div>
   </section>
   <div className={`employee-profile-summary${!attendance || !readable ? ' single' : ''}`}>
    {attendance && <EmployeeAttendance employeeId={id} />}
    {readable && <EmployeeSalarySummary id={id} period={period} onPeriod={setPeriod} />}
   </div>
   <EmployeeHistory employeeId={id} operation={operation} />
  </div>)}
 </PurchaseDialog>;
}

function EmployeeSalarySummary({ id, period, onPeriod }: { id: string; period: string; onPeriod: (value: string) => void }) {
 const month = useEmployeeSalaryMonth(id, period);
 return <section className="employee-panel employee-profile-salary" aria-label="Salary summary">
  <div className="employee-panel-heading"><h3><BadgeDollarSign size={16} aria-hidden="true" />Salary</h3><input aria-label="Salary summary month" className="input-field employee-summary-month" type="month" min="2000-01" max="2100-12" value={period.slice(0, 7)} onChange={ev => { if (ev.target.value) onPeriod(ev.target.value + '-01'); }} /></div>
  <div className="employee-panel-content">
   {month.isPending && <p role="status">Loading salary…</p>}{month.isError && <p role="alert" className="purchase-error">Salary unavailable. <button className="btn btn-ghost" onClick={() => void month.refetch()}>Retry</button></p>}
   {month.data && <><span className={`employee-status-badge ${month.data.outstanding === 0 ? 'paid' : 'unpaid'}`}>{month.data.salary_amount === 0 ? 'No salary due' : month.data.outstanding === 0 ? 'Paid' : 'Payment remaining'}</span><dl className={`employee-salary-totals ${month.data.outstanding > 0 ? 'salary-outstanding' : 'salary-settled'}`}><div><dt>Salary</dt><dd>{formatBDT(month.data.salary_amount)}</dd></div><div><dt>Paid</dt><dd>{formatBDT(month.data.paid)}</dd></div><div><dt>Remaining</dt><dd>{formatBDT(month.data.outstanding)}</dd></div></dl><p className="employee-panel-note">Salary, bonuses and returns appear in Activity history.</p></>}
  </div>
 </section>;
}
