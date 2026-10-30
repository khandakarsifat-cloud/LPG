import { useState } from 'react';
import { Clock3, History } from 'lucide-react';
import { useAttendanceConfiguration, useEmployeeAttendance } from '../../hooks/useAttendance';
import { attendanceTime, workedTime } from '../../lib/attendance';
import { employeeToday } from '../../lib/employee';
import { AttendanceHistory } from './AttendanceHistory';
import './attendance.css';

export function EmployeeAttendance({ employeeId }: { employeeId: string }) {
 const config = useAttendanceConfiguration();
 const today = config.data?.today ?? employeeToday();
 const query = useEmployeeAttendance(employeeId, today.slice(0, 7));
 const current = query.data?.entries.find(day => day.work_date === today);
 const zone = config.data?.timezone ?? 'Asia/Dhaka';
 const linked = !!query.data?.links.some(link => !link.unlinked_at);
 const state = current?.clock_out ? 'Clocked out' : current?.clock_in ? 'Clocked in' : !linked ? 'Not linked' : 'Not clocked in';
 const [history, setHistory] = useState(false);
 return <section className="employee-panel employee-today" aria-label="Attendance status">
  <div className="employee-panel-heading"><h3><Clock3 size={16} aria-hidden="true" />{query.isPending ? 'Loading attendance…' : query.isError ? 'Attendance unavailable' : state}</h3><button className="btn btn-ghost" onClick={() => setHistory(true)}><History size={13} aria-hidden="true" />Attendance history</button></div>
  <div className="employee-panel-content">
   {query.isPending && <p role="status">Loading attendance…</p>}
   {query.isError && <p role="alert" className="purchase-error">Attendance unavailable. <button className="btn btn-ghost" onClick={() => void query.refetch()}>Retry</button></p>}
   {query.data && <>
    <dl className="employee-today-times"><div><dt>Clock in</dt><dd>{attendanceTime(current?.clock_in ?? null, zone)}</dd></div><div><dt>Clock out</dt><dd>{attendanceTime(current?.clock_out ?? null, zone)}</dd></div><div><dt>Worked time</dt><dd>{workedTime(current?.worked_seconds ?? 0)}</dd></div></dl>
    <p className="employee-panel-note">{current ? 'Provisional · presence is an estimate from scans.' : linked ? 'No arrival established by device scans.' : 'Link a device User ID in Edit employee to show this employee’s scans.'}</p>
    {!!current?.warning_count && <p className="employee-clock-warning">{current.warning_count} device clock warning{current.warning_count === 1 ? '' : 's'} excluded.</p>}
   </>}
  </div>
  {history && <AttendanceHistory employeeId={employeeId} onClose={() => setHistory(false)} />}
 </section>;
}
