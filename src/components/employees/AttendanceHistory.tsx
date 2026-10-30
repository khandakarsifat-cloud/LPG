import { useState } from 'react';
import { Pencil, RotateCcw } from 'lucide-react';
import { useAttendanceConfiguration, useAttendanceCorrection, useAttendanceEdit, useAttendanceHistory } from '../../hooks/useAttendance';
import { attendanceTime, localAttendanceInput, workedTime } from '../../lib/attendance';
import { employeeDate } from '../../lib/employee';
import type { AttendanceCorrection, AttendanceEdit, AttendanceView } from '../../types/attendance';
import { PurchaseConfirmation, PurchaseDialog } from '../purchases/PurchaseControls';
import { DatePicker } from '../ui/DatePicker';
import { Pagination } from '../ui/Pagination';

export function AttendanceHistory({ employeeId, onClose }: { employeeId: string; onClose: () => void }) {
 const config = useAttendanceConfiguration(); const zone = config.data?.timezone ?? 'Asia/Dhaka';
 const [view, setView] = useState<AttendanceView>('daily'); const [from, setFrom] = useState(''); const [to, setTo] = useState(''); const [page, setPage] = useState(0);
 const [editing, setEditing] = useState(false);
 const query = useAttendanceHistory(employeeId, view, from, to, page);
 const recovery = useAttendanceCorrection();
 return <PurchaseDialog title="Attendance history" subtitle={`Times in ${zone}`} onClose={onClose} className="attendance-history-dialog">
  <div className="modal-body attendance-history-body">
   {recovery.hasPending && <p className="purchase-alert" role="status">An attendance correction needs confirmation. <button className="btn btn-secondary" disabled={recovery.isPending} onClick={() => recovery.mutate(undefined)}>Recover correction</button></p>}
   {recovery.isError && <p className="purchase-error" role="alert">{recovery.error.message}</p>}
   <div className="attendance-history-heading"><div className="attendance-view-switch" aria-label="Attendance view">{(['daily', 'weekly', 'monthly'] as const).map(item => <button className="btn btn-secondary" aria-pressed={view === item} key={item} onClick={() => { setView(item); setPage(0); }}>{item[0].toUpperCase() + item.slice(1)}</button>)}</div>
    {config.data?.can_correct && <button className="btn btn-primary" onClick={() => setEditing(true)}><Pencil size={14} />Edit history</button>}
   </div>
   <div className="attendance-history-filters"><label className="input-group"><span className="input-label">From</span><DatePicker label="Attendance from" value={from} max={to || undefined} onChange={value => { setFrom(value); setPage(0); }} /></label><label className="input-group"><span className="input-label">To</span><DatePicker label="Attendance to" value={to} min={from || undefined} onChange={value => { setTo(value); setPage(0); }} /></label>{(from || to) && <button className="btn btn-ghost" onClick={() => { setFrom(''); setTo(''); setPage(0); }}><RotateCcw size={14} />Reset</button>}</div>
   {view !== 'daily' && <p className="employee-hint">{view === 'weekly' ? 'Weeks start Monday.' : 'Calendar months.'} Date filters include only days within the selected range.</p>}
   {query.isPending && <p role="status">Loading attendance…</p>}{query.isError && <p className="purchase-error" role="alert">Attendance unavailable. <button className="btn btn-ghost" onClick={() => void query.refetch()}>Retry</button></p>}
   <div className="attendance-history-table" data-view={view}><table><thead><tr><th scope="col">{view === 'daily' ? 'Date' : view === 'weekly' ? 'Week of' : 'Month'}</th>{view === 'daily' ? <><th scope="col">Clock in</th><th scope="col">Clock out</th></> : <th scope="col">Attended days</th>}<th scope="col">Worked time</th></tr></thead>
    <tbody>{query.data?.entries.map(row => <tr key={row.period}><td>{view === 'monthly' ? new Intl.DateTimeFormat('en-BD', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(row.period)) : employeeDate(row.period)}{row.manual && <small>Corrected</small>}{row.automatic_close && <small>Auto closed</small>}</td>{view === 'daily' ? <><td data-label="Clock in">{attendanceTime(row.clock_in, zone)}</td><td data-label="Clock out">{attendanceTime(row.clock_out, zone)}</td></> : <td data-label="Attended days">{row.attended_days}</td>}<td data-label="Worked time">{workedTime(row.worked_seconds)}</td></tr>)}</tbody></table></div>
   {query.data && !query.data.entries.length && <p className="employee-empty">No attendance in this range.</p>}
   <Pagination page={page} pageSize={12} total={query.data?.total ?? 0} onChange={setPage} busy={query.isFetching} label="attendance records" alwaysVisible />
   <p className="employee-hint">A single punch remains open until the workday cutoff, then closes automatically. Later device uploads may revise device estimates. Manual corrections take priority.</p>
  </div><div className="modal-footer"><button className="btn btn-secondary" onClick={onClose}>Close</button></div>
  {editing && config.data && <AttendanceEditDialog employeeId={employeeId} today={config.data.today} timezone={zone} onClose={() => setEditing(false)} />}
 </PurchaseDialog>;
}
function AttendanceEditDialog({ employeeId, today, timezone, onClose }: { employeeId: string; today: string; timezone: string; onClose: () => void }) {
 const [date, setDate] = useState(today); const [reload, setReload] = useState(0); const query = useAttendanceEdit(employeeId, date);
 return <PurchaseDialog title="Edit attendance history" subtitle={`Times in ${timezone}`} onClose={onClose} compact>
  <div className="modal-body attendance-edit-body"><label className="input-group"><span className="input-label">Attendance date</span><DatePicker label="Correction date" value={date} min="2000-01-01" max={today} onChange={setDate} /></label>
   {query.isPending && <p role="status">Loading existing attendance…</p>}{query.isError && <p role="alert" className="purchase-error">Attendance unavailable. <button className="btn btn-ghost" onClick={() => void query.refetch()}>Reload attendance</button></p>}
   {query.data && <AttendanceCorrectionForm key={`${date}:${reload}`} employeeId={employeeId} date={date} data={query.data} timezone={timezone} onClose={onClose} onReload={() => { void query.refetch().then(() => setReload(value => value + 1)); }} />}
  </div>
 </PurchaseDialog>;
}
function AttendanceCorrectionForm({ employeeId, date, data, timezone, onClose, onReload }: { employeeId: string; date: string; data: AttendanceEdit; timezone: string; onClose: () => void; onReload: () => void }) {
 const [baseline] = useState(data);
 const [clockIn, setClockIn] = useState(localAttendanceInput(baseline.day?.clock_in ?? null, timezone)); const [clockOut, setClockOut] = useState(localAttendanceInput(baseline.day?.clock_out ?? null, timezone));
 const [reason, setReason] = useState(''); const [confirmed, setConfirmed] = useState<AttendanceCorrection | null>(null); const operation = useAttendanceCorrection(onClose);
 return <>
  <dl className="employee-confirm-details"><div><dt>Current clock in</dt><dd>{localAttendanceInput(baseline.day?.clock_in ?? null, timezone).replace('T', ' ') || 'None'}</dd></div><div><dt>Current clock out</dt><dd>{localAttendanceInput(baseline.day?.clock_out ?? null, timezone).replace('T', ' ') || 'None'}</dd></div></dl>
  <form className="attendance-form" onSubmit={event => { event.preventDefault(); setConfirmed({ employee_id: employeeId, day: date, clock_in: clockIn, clock_out: clockOut, reason: reason.trim(), revision: baseline.day?.revision ?? 0, request_id: crypto.randomUUID() }); }}>
   <fieldset className="employee-fields" disabled={operation.isPending || operation.hasPending}><label>Corrected clock in<input className="input-field" type="datetime-local" step="1" value={clockIn} onChange={event => setClockIn(event.target.value)} /></label><label>Corrected clock out<input className="input-field" type="datetime-local" step="1" value={clockOut} onChange={event => setClockOut(event.target.value)} /></label>
    <label>Reason for correction<textarea className="input-field" required maxLength={1000} rows={2} value={reason} onChange={event => setReason(event.target.value)} /></label>
    <p className="employee-hint">Clear both times to mark this day as not attended. Raw machine punches and earlier corrections are retained.</p>
   </fieldset>
   <div className="employee-quick-actions"><button type="button" className="btn btn-secondary" onClick={onClose} disabled={operation.isPending}>Cancel</button><button className="btn btn-primary" disabled={!reason.trim() || operation.isPending || operation.hasPending}>Review changes</button></div>
   {operation.hasPending && !confirmed && <p role="status">Recover the pending correction from Attendance history before another change.</p>}
  </form>
  {!!baseline.adjustments.length && <section className="attendance-audit"><h3>Recent corrections</h3>{baseline.adjustments.map(item => <article key={item.adjustment_id}><strong>{item.actor || 'Authorized operator'}</strong><time>{new Date(item.created_at).toLocaleString('en-BD', { timeZone: timezone })}</time><p>{item.reason}</p><small>{attendanceTime(item.before_values.clock_in ?? null, timezone)} – {attendanceTime(item.before_values.clock_out ?? null, timezone)} → {attendanceTime(item.clock_in, timezone)} – {attendanceTime(item.clock_out, timezone)}</small></article>)}</section>}
  {confirmed && <PurchaseConfirmation title="Confirm attendance correction" action={operation.hasPending ? 'Recover correction' : 'Apply correction'} busy={operation.isPending} onCancel={() => setConfirmed(null)} onConfirm={() => operation.mutate(operation.hasPending ? undefined : confirmed)}>
   <p>Update attendance for <strong>{employeeDate(date)}</strong> in {timezone}.</p><dl className="employee-change-list"><div><dt>Clock in</dt><dd>{localAttendanceInput(baseline.day?.clock_in ?? null, timezone).replace('T', ' ') || 'None'} → {confirmed.clock_in.replace('T', ' ') || 'None'}</dd></div><div><dt>Clock out</dt><dd>{localAttendanceInput(baseline.day?.clock_out ?? null, timezone).replace('T', ' ') || 'None'} → {confirmed.clock_out.replace('T', ' ') || (confirmed.clock_in ? 'Automatic at workday cutoff' : 'None')}</dd></div><div><dt>Reason</dt><dd>{confirmed.reason}</dd></div></dl><p>Daily, weekly and monthly totals will reflect these times. Original machine records remain unchanged.</p>
   {operation.isError && <p className="purchase-error" role="alert">{operation.error.message} <button className="btn btn-ghost" onClick={() => { setConfirmed(null); onReload(); }}>Reload attendance</button></p>}
  </PurchaseConfirmation>}
 </>;
}
