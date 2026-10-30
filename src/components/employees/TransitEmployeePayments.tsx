import { useState } from 'react';
import { useAuth } from '../../contexts/AuthContext';
import { useEmployeeProfile, useEmployeeOperation } from '../../hooks/useEmployees';
import { EmployeePaymentDialog } from './EmployeePayments';
import { EmployeeOperationNotice } from './EmployeeForm';
import type { Transit } from '../../types/logistics';

export function TransitEmployeePayButton({ transit, paid, disabled }: { transit: Transit; paid: { driver_paid: number; helper_paid: number }; disabled: boolean }) {
 const { can } = useAuth(); const [role, setRole] = useState<'driver' | 'helper' | null>(null); const operation = useEmployeeOperation();
 const id = role === 'driver' ? transit.driver_employee_id : role === 'helper' ? transit.helper_employee_id : null;
 const profile = useEmployeeProfile(id ?? '');
 const remaining = role === 'driver' ? Number(transit.driver_cost) - paid.driver_paid : Number(transit.helper_cost) - paid.helper_paid;
 if (!can('payroll:pay') || !can('logistics:manage') || transit.closed_at) return null;
 return <><div className="logistics-payment-actions">{(['driver', 'helper'] as const).map(r => <button key={r} type="button" className="btn btn-secondary" disabled={disabled || operation.hasPending || !(r === 'driver' ? transit.driver_employee_id && Number(transit.driver_cost) > paid.driver_paid : transit.helper_employee_id && Number(transit.helper_cost) > paid.helper_paid)} onClick={() => setRole(r)}>Pay {r}</button>)}</div><EmployeeOperationNotice operation={operation} />{role && profile.isPending && <p role="status">Loading employee…</p>}{role && profile.isError && <p className="purchase-error" role="alert">Employee unavailable. <button type="button" className="btn btn-secondary" onClick={() => void profile.refetch()}>Retry</button></p>}{role && profile.data && <EmployeePaymentDialog employee={profile.data.employee} operation={operation} onClose={() => setRole(null)} trip={{ transit_id: transit.transit_id, role, amount: remaining }} />}</>;
}
