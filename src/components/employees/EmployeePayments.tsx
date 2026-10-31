import { useState } from 'react';
import './employees.css';
import { PaymentEntries } from '../pos/PaymentEntries';
import toast from 'react-hot-toast';
import { usePaymentWallets } from '../../hooks/useFinance';
import { useEmployeeSalaryMonth, useTripPaymentWallets } from '../../hooks/useEmployees';
import { formatBDT } from '../../lib/formatBDT';
import { employeeDate, employeeMonth, employeeToday, monthLabel } from '../../lib/employee';
import { paymentDraft, validatePayments } from '../../lib/payments';
import { DatePicker } from '../ui/DatePicker';
import { PurchaseConfirmation, PurchaseDialog, PurchaseNumber, PurchaseSelect } from '../purchases/PurchaseControls';
import { EmployeeOperationNotice, type EmployeeOperationHandle } from './EmployeeForm';
import type { Employee, EmployeeSalaryMonth } from '../../types/employee';
import type { PaymentWallet } from '../../types/finance';


interface PaymentProps {
 employee: Employee; period?: string; kind?: 'salary' | 'bonus'; operation: EmployeeOperationHandle; onClose: () => void; inline?: boolean;
 trip?: { transit_id: string; role: 'driver' | 'helper'; amount: number };
}
export function EmployeePaymentDialog({ employee, period: initialPeriod, kind = 'salary', operation, onClose, trip, inline = false }: PaymentProps) {
 const [period, setPeriod] = useState(initialPeriod ?? employeeMonth());
 const normalWallets = usePaymentWallets(!trip); const tripWallets = useTripPaymentWallets(trip?.transit_id); const wallets = trip ? tripWallets : normalWallets;
 const salary = useEmployeeSalaryMonth(employee.employee_id, period, kind === 'salary' && !trip);
 const ready = kind === 'bonus' || !!trip || !!salary.data;
 const content = <>
  {!trip && kind === 'salary' && <div className="employee-payment-month"><label className="input-group"><span className="input-label">Salary month</span><input type="month" className="input-field" aria-label="Salary month" min="2000-01" max="2100-12" value={period.slice(0, 7)} disabled={operation.isPending || operation.hasPending} onChange={ev => { if (ev.target.value) setPeriod(ev.target.value + '-01'); }} /></label></div>}
  {(wallets.isPending || (!ready && salary.isPending)) && <p className="modal-body" role="status">Loading payment details…</p>}
  {(wallets.error || (kind === 'salary' && !trip && salary.error)) && <p className="modal-body purchase-error" role="alert">Payment details could not be loaded. <button className="btn btn-secondary" onClick={() => { void wallets.refetch(); if (kind === 'salary' && !trip) void salary.refetch(); }}>Retry</button></p>}
  {wallets.data && ready && <EmployeePaymentForm key={period} employee={employee} wallets={wallets.data} period={period} kind={kind} salary={salary.data} operation={operation} onClose={onClose} trip={trip} />}
 </>;
 return inline ? content : <PurchaseDialog title={trip ? 'Pay driver / helper' : kind === 'bonus' ? 'Give bonus' : 'Pay salary'} subtitle={employee.name} onClose={onClose} busy={operation.isPending} compact>{content}</PurchaseDialog>;
}
function EmployeePaymentForm({ employee, wallets, period, kind, salary, operation, onClose, trip }: Omit<PaymentProps, 'inline' | 'kind' | 'period'> & { wallets: PaymentWallet[]; kind: 'salary' | 'bonus'; period: string; salary?: EmployeeSalaryMonth }) {
 const limit = trip?.amount ?? (kind === 'salary' ? salary?.outstanding ?? 0 : Infinity);
 const initial = Number.isFinite(limit) ? limit : 0;
 const [amount, setAmount] = useState(initial);
 const [wallet, setWallet] = useState(() => paymentDraft(wallets, 0).wallet_id);
 const [date, setDate] = useState(employeeToday()); const [description, setDescription] = useState(''); const [name, setName] = useState('');
 const [confirming, setConfirming] = useState(false);
 const disabled = operation.isPending || operation.hasPending;
 const drafts = [{ id: 'simple', wallet_id: wallet, amount: amount.toFixed(2), reference: '' }];
 const [tripEntries, setTripEntries] = useState(() => [{ ...paymentDraft(wallets, initial), wallet_id: wallet }]);
 const validation = validatePayments(trip ? tripEntries : drafts, Number.isFinite(limit) ? limit : amount, wallets);
 async function submit() {
  if (disabled || validation.error || validation.paid <= 0 || validation.paid > limit || !date || (kind === 'bonus' && !name.trim())) return;
  try {
   await operation.mutateAsync({ action: 'pay', items: [{ employee_id: employee.employee_id, kind: trip ? 'trips' : kind,
    ...(kind === 'salary' && !trip ? { period } : {}), ...(kind === 'bonus' ? { bonus_name: name.trim() } : {}),
    payment_date: date, description, payments: validation.payments,
    ...(trip ? { trip_count: 1, transit_id: trip.transit_id, trip_role: trip.role } : {}) }] });
   toast.success(kind === 'bonus' ? 'Bonus recorded' : 'Payment recorded', { position: 'bottom-center' }); onClose();
  } catch { /* The original request remains recoverable. */ }
 }
 return <>{confirming && <PurchaseConfirmation title="Confirm employee payment" action={`Confirm payment · ${formatBDT(validation.paid)}`} busy={operation.isPending} confirmDisabled={disabled || !!validation.error || validation.paid <= 0 || validation.paid > limit} onCancel={() => setConfirming(false)} onConfirm={() => void submit()}>
  <p>Record a payment to <strong>{employee.name}</strong> from the wallet below.</p>
  <dl className="employee-confirm-details"><div><dt>Amount</dt><dd className="employee-confirm-amount">{formatBDT(validation.paid)}</dd></div><div><dt>For</dt><dd>{trip ? `Trip · ${trip.role}` : kind === 'bonus' ? `Bonus · ${name.trim()}` : `Salary · ${monthLabel(period)}`}</dd></div><div><dt>From wallet</dt><dd>{trip ? validation.payments.map(p => `${wallets.find(w => w.wallet_id === p.wallet_id)?.name}: ${formatBDT(p.amount)}`).join(', ') : wallets.find(w => w.wallet_id === wallet)?.name}</dd></div><div><dt>Payment date</dt><dd>{employeeDate(date)}</dd></div>{description.trim() && <div><dt>Note</dt><dd>{description.trim()}</dd></div>}{kind === 'salary' && !trip && <div><dt>Salary remaining after payment</dt><dd>{formatBDT(Math.max(0, limit - validation.paid))}</dd></div>}</dl>
  <p className="employee-hint">This records money paid and deducts it from the selected wallet. It does not send a bank or mobile payment.</p><EmployeeOperationNotice operation={operation} onRecovered={onClose} />
 </PurchaseConfirmation>}<form onSubmit={ev => { ev.preventDefault(); if (!disabled && !validation.error && validation.paid > 0 && validation.paid <= limit) setConfirming(true); }}><div className="modal-body employee-form">
  <fieldset className="employee-fields" disabled={disabled}>
   {kind === 'salary' && !trip && salary && <div className="employee-pay-summary"><span>Remaining salary</span><strong>{formatBDT(salary.outstanding)}</strong><small>{formatBDT(salary.salary_amount)} salary · {formatBDT(salary.paid)} paid</small></div>}
   {kind === 'bonus' && <label className="input-group"><span className="input-label">Bonus name</span><input required className="input-field" placeholder="e.g. Eid Bonus" maxLength={120} value={name} onChange={ev => setName(ev.target.value)} /></label>}
   {trip ? <PaymentEntries entries={tripEntries} onChange={setTripEntries} wallets={wallets} total={limit} disabled={disabled} /> : <div className="employee-form-grid"><PurchaseNumber label="Pay now (Tk)" money value={amount} onChange={value => setAmount(value ?? 0)} /><PurchaseSelect label="Pay from wallet" value={wallet} options={wallets.map(w => ({ value: w.wallet_id, label: w.name }))} onChange={setWallet} /></div>}
   <details className="employee-more" open={kind === 'bonus'}><summary>Payment date & note</summary><label className="input-group"><span className="input-label">Payment date</span><DatePicker label="Payment date" value={date} onChange={setDate} max={employeeToday()} /></label><label className="input-group"><span className="input-label">Description (optional)</span><textarea className="input-field" rows={2} maxLength={1000} value={description} onChange={ev => setDescription(ev.target.value)} /></label></details>
   {kind === 'salary' && !trip && limit === 0 && <p className="employee-hint">{salary?.salary_amount ? 'This month is fully paid.' : 'No salary is due for this month. Choose a month during employment.'}</p>}
   {trip && <p className="employee-hint">Pays the recorded {trip.role} earnings. Partial payments leave the remaining earnings outstanding. Completion requires both crew balances to be fully paid.</p>}
  </fieldset>
  {validation.error && validation.paid > 0 && <p role="alert" className="purchase-error">{validation.error}</p>}<EmployeeOperationNotice operation={operation} onRecovered={onClose} />
 </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={onClose}>Back</button><button className="btn btn-primary" disabled={disabled || !!validation.error || validation.paid <= 0 || !date || !wallets.length || (kind === 'bonus' && !name.trim()) || validation.paid > limit}>{operation.isPending ? 'Recording…' : `Pay ${formatBDT(validation.paid)}`}</button></div></form></>;
}
