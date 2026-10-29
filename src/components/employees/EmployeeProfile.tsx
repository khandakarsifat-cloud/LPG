import { useState } from 'react';
import { Pencil, Phone, MapPin, BadgeDollarSign, Gift, ArrowLeft } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { useEmployeeSalaryHistory, useEmployeeProfile } from '../../hooks/useEmployees';
import { employeeDate, employeeMonth, employeeUnitLabels, employeeStatus, monthLabel } from '../../lib/employee';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { EmployeeForm, type EmployeeOperationHandle } from './EmployeeForm';
import { EmployeePaymentDialog } from './EmployeePayments';
import { EmployeeHistory } from './EmployeeHistory';

export function EmployeeProfileDialog({ id, types, operation, onClose }: { id: string; types: string[]; operation: EmployeeOperationHandle; onClose: () => void }) {
 const { can } = useAuth(); const readable = can('payroll:view') || can('payroll:pay'); const query = useEmployeeProfile(id); const e = query.data?.employee;
 const [page, setPage] = useState(0); const months = useEmployeeSalaryHistory(id, page, readable);
 const [view, setView] = useState<'profile' | 'edit' | 'edit-salary' | 'salary' | 'bonus'>('profile'); const [period, setPeriod] = useState(employeeMonth());
 const disabled = operation.isPending || operation.hasPending;
 const pay = (month: string) => { setPeriod(month); setView('salary'); };
 return <PurchaseDialog title={view === 'profile' ? 'Employee profile' : view === 'edit' || view === 'edit-salary' ? 'Edit employee' : view === 'salary' ? 'Pay salary' : 'Give bonus'} subtitle={e?.name} onClose={onClose} busy={operation.isPending} className="employee-profile-dialog">
  {view !== 'profile' && <div className="employee-profile-back"><button className="btn btn-ghost" disabled={operation.isPending} onClick={() => setView('profile')}><ArrowLeft size={15} />Profile</button></div>}
  {query.isPending && <p className="modal-body" role="status">Loading employee…</p>}{query.error && <p role="alert" className="modal-body purchase-error">Employee could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
  {e && query.data && (view === 'edit' || view === 'edit-salary' ? <EmployeeForm inline editSalary={view === 'edit-salary'} profile={query.data} types={types} operation={operation} onClose={() => setView('profile')} /> : view === 'salary' || view === 'bonus' ? <EmployeePaymentDialog inline employee={e} period={period} kind={view} operation={operation} onClose={() => setView('profile')} /> : <>
   <div className="modal-body employee-profile-body">
    <div className="employee-identity"><span className="employee-avatar">{e.name.slice(0, 1).toUpperCase()}</span><div><h3>{e.name}</h3><p>{e.employee_type_name || 'Employee'} · {employeeUnitLabels[e.business_unit]}</p><span className={`employee-status-badge ${e.is_active ? 'active' : 'inactive'}`}>{employeeStatus(e)}</span></div>{can('employees:manage') && <button className="btn btn-secondary" onClick={() => setView('edit')} disabled={disabled}><Pencil size={14} />Edit</button>}</div>
    <div className="employee-contact">{e.phones.map(p => <a key={p.phone} href={`tel:${p.phone}`}><Phone size={13} />{p.phone}</a>)}{e.address && <span><MapPin size={13} />{e.address}</span>}</div>
    <div className="employee-salary-config"><div><small>Monthly salary</small><strong>{formatBDT(e.current_salary)}</strong></div>{can('employees:manage') && <button className="btn btn-ghost" disabled={disabled} onClick={() => setView('edit-salary')}>Edit salary</button>}</div>
    {can('payroll:pay') && <div className="employee-quick-actions"><button className="btn btn-primary" disabled={disabled} onClick={() => pay(employeeMonth())}><BadgeDollarSign size={16} />Pay salary</button><button className="btn btn-secondary" disabled={disabled} onClick={() => setView('bonus')}><Gift size={16} />Give bonus</button></div>}
    <details className="employee-employment"><summary>Employment & salary revisions</summary>{e.notes && <p>{e.notes}</p>}<p className="employee-hint">Joined {employeeDate(e.joining_date)}. Saved salary months retain their amounts.</p><div className="employee-terms-list">{query.data.terms.map(term => <div key={term.term_id}><span>{employeeDate(term.effective_from)}<small>{term.reason}</small></span><strong>{term.is_active ? formatBDT(term.monthly_salary) + ' / month' : 'Inactive'}</strong></div>)}</div><p className="employee-hint">Latest 24 revisions; older revisions remain in activity history.</p></details>
    {readable && <><section className="employee-periods" aria-label="Monthly salary history"><div className="employee-section-heading"><h3>Monthly salary history</h3><small>Salary · Paid · Remaining</small></div>
     {months.isPending && <p role="status">Loading salary history…</p>}{months.error && <p className="purchase-error" role="alert">Salary history could not be loaded. <button className="btn btn-secondary" onClick={() => void months.refetch()}>Retry</button></p>}
     {months.data?.entries.map(month => <article key={month.period} className="employee-period-row"><div className="employee-period-heading"><strong>{monthLabel(month.period)}</strong>{can('payroll:pay') && month.outstanding > 0 ? <button className="btn btn-ghost" disabled={disabled} aria-label={`Pay ${monthLabel(month.period)}`} onClick={() => pay(month.period)}>Pay salary</button> : <span className={`employee-status-badge ${month.outstanding === 0 ? 'paid' : 'unpaid'}`}>{month.salary_amount === 0 ? 'No salary due' : month.outstanding === 0 ? 'Paid' : 'Outstanding'}</span>}</div><dl className="employee-period-totals"><div><dt>Salary</dt><dd>{formatBDT(month.salary_amount)}</dd></div><div><dt>Paid</dt><dd>{formatBDT(month.paid)}</dd></div><div><dt>Remaining</dt><dd>{formatBDT(month.outstanding)}</dd></div></dl></article>)}
     {months.data && !months.data.entries.length && <p className="employee-hint">Salary history appears from the joining month. Future months are available through Pay salary.</p>}<Pagination page={page} pageSize={6} total={months.data?.total ?? 0} onChange={setPage} label="salary months" busy={months.isFetching} />
    </section><EmployeeHistory employeeId={id} operation={operation} /></>}
   </div>
  </>)}
 </PurchaseDialog>;
}
