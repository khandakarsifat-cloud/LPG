import { useState } from 'react';
import { useAuth } from '../../contexts/AuthContext';
import { useEmployeeDirectory, useEmployeeOperation } from '../../hooks/useEmployees';
import { defaultEmployeeFilters, employeeMonth } from '../../lib/employee';
import { EmployeePaymentDialog } from './EmployeePayments';
import { EmployeeOperationNotice } from './EmployeeForm';
import { PurchaseSelect } from '../purchases/PurchaseControls';
import type { Employee } from '../../types/employee';
import type { Transit } from '../../types/logistics';
import './employees.css';

export function TransitEmployeePayButton({ transit, paid, disabled }: { transit: Transit; paid: { driver_paid: number; helper_paid: number }; disabled: boolean }) {
 const { can } = useAuth(); const [open, setOpen] = useState(false);
 return can('payroll:pay') && can('logistics:manage') && !transit.closed_at ? <><button type="button" className="btn btn-secondary" disabled={disabled} onClick={() => setOpen(!open)} aria-expanded={open}>Pay driver / helper</button>{open && <TransitEmployeePicker transit={transit} paid={paid} />}</> : null;
}
function TransitEmployeePicker({ transit, paid }: { transit: Transit; paid: { driver_paid: number; helper_paid: number } }) {
 const [search, setSearch] = useState(''); const [id, setId] = useState(''); const [role, setRole] = useState<'driver' | 'helper'>('driver'); const [pay, setPay] = useState<Employee | null>(null);
 const directory = useEmployeeDirectory({ ...defaultEmployeeFilters, search }, 25); const operation = useEmployeeOperation();
 const remaining = (role === 'driver' ? Number(transit.driver_cost) - paid.driver_paid : Number(transit.helper_cost) - paid.helper_paid);
 const employee = directory.data?.entries.find(e => e.employee_id === id);
 return <div className="employee-form"><label className="input-group"><span className="input-label">Find employee</span><input className="input-field" value={search} placeholder="Search name or phone" onChange={ev => { setSearch(ev.target.value); setId(''); }} /></label><PurchaseSelect label="Employee" value={id} options={directory.data?.entries.map(e => ({ value: e.employee_id, label: e.name })) ?? []} onChange={setId} />{directory.isError && <p className="purchase-error" role="alert">Employees could not be loaded.</p>}<PurchaseSelect label="Trip cost allocation" value={role} options={[{ value: 'driver', label: 'Driver cost' }, { value: 'helper', label: 'Helper cost' }]} onChange={value => setRole(value as 'driver' | 'helper')} /><p className="employee-hint">Search narrows the first 25 results. Saved employee payouts reduce the amount charged on trip closure.</p><button type="button" className="btn btn-primary" disabled={!employee || remaining <= 0 || operation.isPending || operation.hasPending} onClick={() => { if (employee) setPay(employee); }}>Pay employee</button><EmployeeOperationNotice operation={operation} />{pay && <EmployeePaymentDialog employee={pay} period={employeeMonth()} operation={operation} onClose={() => setPay(null)} trip={{ transit_id: transit.transit_id, role, amount: remaining }} />}</div>;
}
