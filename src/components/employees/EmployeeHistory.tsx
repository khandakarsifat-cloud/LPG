import { useEffect, useState } from 'react';
import { CalendarDays, Clock3, History, RotateCcw, Search, UserRound, Wallet } from 'lucide-react';
import toast from 'react-hot-toast';
import { useAuth } from '../../contexts/AuthContext';
import { useEmployeeActivity } from '../../hooks/useEmployees';
import { defaultActivityFilters, employeeDate, employeeToday, monthLabel } from '../../lib/employee';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseSelect } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { DatePicker } from '../ui/DatePicker';
import { EmployeeOperationNotice, type EmployeeOperationHandle } from './EmployeeForm';
import type { EmployeeActivity } from '../../types/employee';
import { useTransit } from '../../hooks/useLogistics';
import { TransitCostsModal } from '../logistics/TransitCostsModal';
import { workedTime } from '../../lib/attendance';

export function EmployeeHistory({ employeeId, operation }: { employeeId?: string; operation: EmployeeOperationHandle }) {
 const { can } = useAuth(); const [filters, setFilters] = useState({ ...defaultActivityFilters, employee_id: employeeId }); const [deferred, setDeferred] = useState(filters); const [page, setPage] = useState(0);
 const [reversal, setReversal] = useState<EmployeeActivity | null>(null); const [advanced, setAdvanced] = useState(false);
 useEffect(() => { const timer = setTimeout(() => setDeferred(filters), 200); return () => clearTimeout(timer); }, [filters]);
 const [transitId,setTransitId] = useState<string|null>(null); const transit=useTransit(transitId);
 const query = useEmployeeActivity(deferred, page);
 return <section className="employee-panel employee-history" aria-label="Employee activity history"><div className="employee-panel-heading"><h3><History size={16} aria-hidden="true" />Activity history</h3><button className="btn btn-ghost" onClick={() => setAdvanced(!advanced)} aria-expanded={advanced}>Filters</button></div>
  <div className="employee-history-toolbar">
  <div className="employee-search"><Search size={15} /><input className="input-field" aria-label="Search employee activity" placeholder="Search payments, changes, notes or references" value={filters.search} onChange={ev => { setPage(0); setFilters({ ...filters, search: ev.target.value }); }} /></div>
  <div className="employee-form-grid employee-history-filters"><PurchaseSelect label="Activity type" value={filters.kind} options={[{ value: '', label: 'All activity' }, { value: 'attendance', label: 'Attendance' }, {value:'transit',label:'Transit participation'}, {value:'assignment',label:'Vehicle assignments'}, ...(can('payroll:view') || can('payroll:pay') ? [{ value: 'payment', label: 'Payments' }, { value: 'reversal', label: 'Returned funds' }] : []), { value: 'terms', label: 'Employment changes' }, { value: 'profile', label: 'Profile changes' }]} onChange={kind => { setPage(0); setFilters({ ...filters, kind }); }} />{advanced && <><label className="input-group"><span className="input-label">From</span><DatePicker label="Activity from" value={filters.from} onChange={from => { setPage(0); setFilters({ ...filters, from }); }} max={filters.to || undefined} /></label><label className="input-group"><span className="input-label">To</span><DatePicker label="Activity to" value={filters.to} onChange={to => { setPage(0); setFilters({ ...filters, to }); }} min={filters.from || undefined} /></label><button className="btn btn-ghost" onClick={() => { setPage(0); setFilters({ ...defaultActivityFilters, employee_id: employeeId }); }}>Clear filters</button></>}</div>
  </div>
  {query.isPending && <p role="status" className="employee-empty">Loading activity…</p>}{query.error && <p role="alert" className="purchase-error">Activity could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
  <div className="employee-activity-list history-list" aria-busy={query.isFetching}>{query.data?.entries.map(event => <article key={event.id} data-activity-id={event.id} className={`employee-activity-row history-card activity-${event.kind}`}>
   <header className="employee-activity-header"><span className={`employee-status-badge ${event.kind}`}>{activityLabels[event.kind]}</span><time className="employee-activity-time" dateTime={event.occurred_at ?? event.created_at}>{activityTimestamp(event.occurred_at ?? event.created_at, event.details.timezone)}</time></header>
   <div className="employee-activity-main"><strong className="employee-activity-description">{!employeeId && `${event.employee_name} · `}{event.description.replaceAll('_', ' ')}</strong>{event.amount !== null && <strong className="employee-activity-amount">{formatBDT(event.amount)}{event.kind === 'terms' ? ' / month' : ''}</strong>}</div>
   <div className="employee-activity-meta">
    {event.kind === 'attendance' ? <><span><Clock3 size={12} aria-hidden="true" />{event.details.manual ? 'Manually corrected' : event.details.automatic_close ? 'Automatically closed' : 'Device attendance'}</span>{event.description === 'Clock out' && <span>{workedTime(event.details.worked_seconds ?? 0)} worked</span>}{!!event.details.warning_count && <span className="employee-clock-warning">{event.details.warning_count} clock warnings excluded</span>}</>
    : <><span><UserRound size={12} aria-hidden="true" />{event.actor || 'Historical record'}</span>{(event.kind === 'terms' || event.date !== event.created_at.slice(0, 10)) && <span><CalendarDays size={12} aria-hidden="true" />{event.kind === 'terms' ? 'Effective' : 'Payment date'} {employeeDate(event.date)}</span>}</>}
    {event.details.reason && <span>{event.details.reason}</span>}
   </div>
   {event.kind === 'transit' && event.details.transit_id && (can('logistics:view') || can('logistics:manage')) && <button className="btn btn-ghost" onClick={() => setTransitId(event.details.transit_id ?? null)}>Transit details</button>}
   {!!event.wallets.length && <div className="employee-activity-wallets">{event.wallets.map(wallet => <span key={wallet.entry_id} data-transaction-id={wallet.transaction_id}><Wallet size={13} aria-hidden="true" /><span>{wallet.wallet_name}</span><strong>{formatBDT(wallet.amount)}</strong>{wallet.reference && ` · ${wallet.reference}`}</span>)}</div>}
   {event.details.source_snapshot && <p className="employee-hint">Historical payment · wallet attribution was not recorded. No wallet debit has been invented.</p>}
   {(event.details.period || (event.reversible && can('payroll:pay'))) && <div className="history-actions">{event.details.period && <span className="employee-period-tag">{monthLabel(event.details.period)}</span>}

   {event.reversible && can('payroll:pay') && <button className="btn btn-ghost employee-reverse" disabled={operation.isPending || operation.hasPending} onClick={() => setReversal(reversal?.id === event.id ? null : event)}><RotateCcw size={13} />Return / correct payment</button>}</div>}
   {reversal?.id === event.id && <EmployeeReversal event={reversal} operation={operation} onClose={() => setReversal(null)} />}
  </article>)}</div>
  {query.data && !query.data.entries.length && <p className="employee-empty">No activity matches these filters.</p>}<Pagination page={page} pageSize={12} total={query.data?.total ?? 0} onChange={setPage} label="employee activity" busy={query.isFetching} />
 {transitId && transit.data && <TransitCostsModal open transit={transit.data} onClose={() => setTransitId(null)} />}
 </section>;
}
const activityLabels = { profile: 'Profile', terms: 'Employment', payment: 'Payment', reversal: 'Returned funds', attendance: 'Attendance', transit: 'Transit', assignment: 'Vehicle assignment' };
function activityTimestamp(value: string, timezone = 'Asia/Dhaka') {
 return new Intl.DateTimeFormat('en-BD', { timeZone: timezone, month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(value));
}
function EmployeeReversal({ event, operation, onClose }: { event: EmployeeActivity; operation: EmployeeOperationHandle; onClose: () => void }) {
 const [reason, setReason] = useState(''); const [date, setDate] = useState(employeeToday()); const [confirmed, setConfirmed] = useState(false);
 return <div className="employee-reversal-form"><h3>Return / correct payment</h3><div className="employee-form"><p className="employee-hint">Record {formatBDT(Math.abs(event.amount ?? 0))} returned to the original wallets. To correct a payment, record the return and then enter the correct payment.</p><label className="input-group"><span className="input-label">Reason</span><textarea rows={2} className="input-field" maxLength={1000} value={reason} onChange={ev => setReason(ev.target.value)} /></label><label className="input-group"><span className="input-label">Funds returned on</span><DatePicker label="Funds returned on" value={date} onChange={setDate} min={event.date} max={employeeToday()} /></label><label className="employee-check"><input type="checkbox" checked={confirmed} onChange={ev => setConfirmed(ev.target.checked)} />Funds have been returned to the original wallets.</label><EmployeeOperationNotice operation={operation} onRecovered={onClose} /><div className="employee-quick-actions"><button className="btn btn-secondary" disabled={operation.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={operation.isPending || operation.hasPending || !reason.trim() || !confirmed || !date} onClick={async () => { try { await operation.mutateAsync({ action: 'reverse_payment', payment_id: event.id, reason, payment_date: date }); toast.success('Return recorded', { position: 'bottom-center' }); onClose(); } catch { /* retained */ } }}>Record return</button></div></div></div>;
}
