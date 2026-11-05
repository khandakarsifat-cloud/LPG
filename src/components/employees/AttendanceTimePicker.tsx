import { useMemo } from 'react';
import { localAttendanceInput } from '../../lib/attendance';

interface Props {
 label: string; value: string; onChange: (value: string) => void;
 start: string; end: string; latest: string; timezone: string;
 other: string; arrival: boolean;
}

/** Choices are generated from real instants in the server's historical workday. */
export function AttendanceTimePicker({ label, value, onChange, start, end, latest, timezone, other, arrival }: Props) {
 const choices = useMemo(() => {
  const formatter = new Intl.DateTimeFormat('sv-SE', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
  const result = new Set<string>();
  const upper = Math.min(Date.parse(end) - 1, Date.parse(latest));
  for (let instant = Math.ceil(Date.parse(start) / 60000) * 60000; instant <= upper; instant += 60000) {
   const local = formatter.format(new Date(instant)).replace(' ', 'T');
   if (!other || (arrival ? local < other : local > other)) result.add(local);
  }
  // Keep the exact seconds of an existing endpoint unless the operator edits it.
  if (value && value >= localAttendanceInput(start, timezone) && value <= localAttendanceInput(new Date(upper).toISOString(), timezone)
   && (!other || (arrival ? value < other : value > other))) result.add(value);
  return [...result].sort();
 }, [start, end, latest, timezone, arrival, other, value]);
 const date = localAttendanceInput(start, timezone).slice(0, 10);
 const dayChoices = choices.filter(item => item.startsWith(date));
 const hours = [...new Set(dayChoices.map(item => item.slice(11, 13)))];
 const hour = value.slice(11, 13);
 const minutes = [...new Set(dayChoices.filter(item => item.slice(11, 13) === hour).map(item => item.slice(14, 16)))];
 return <fieldset className="attendance-clock">
  <legend>{label}</legend>
  <div className="attendance-clock-controls">

   <label><span>Hour</span><select className="input-field" aria-label={`${label} hour`} value={hour} onChange={event => onChange(dayChoices.find(item => item.slice(11, 13) === event.target.value) ?? '')}><option value="">Not set</option>{hours.map(item => <option key={item} value={item}>{Number(item) % 12 || 12} {Number(item) < 12 ? 'AM' : 'PM'}</option>)}</select></label>
   <label><span>Minute</span><select className="input-field" aria-label={`${label} minute`} value={value.slice(14, 16)} disabled={!value} onChange={event => onChange(dayChoices.find(item => item.slice(11, 16) === `${hour}:${event.target.value}`) ?? '')}><option value="">—</option>{minutes.map(item => <option key={item} value={item}>{item}</option>)}</select></label>
  </div>
  {value && <button type="button" className="btn btn-ghost" onClick={() => onChange('')}>Clear {label.toLowerCase()}</button>}
 </fieldset>;
}
