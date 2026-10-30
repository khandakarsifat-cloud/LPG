import type { AttendanceDevice } from '../types/attendance';

export function attendanceTime(value: string | null, timezone: string) {
 return value ? new Intl.DateTimeFormat('en-BD', { timeZone: timezone, hour: 'numeric', minute: '2-digit', second: '2-digit' }).format(new Date(value)) : '—';
}
export function attendanceConnection(device: AttendanceDevice, now = Date.now()) {
 if (!device.approved) return 'Awaiting approval';
 if (!device.enabled) return 'Disabled';
 if (!device.last_seen_at) return 'Waiting for first connection';
 return now - new Date(device.last_seen_at).getTime() <= 3 * 60_000 ? 'Seen recently' : 'Connection stale';
}
export function workedTime(seconds: number) {
 const minutes = Math.floor(seconds / 60);
 return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}
export function localAttendanceInput(value: string | null, timezone: string) {
 if (!value) return '';
 const parts = new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(value));
 const get = (type: Intl.DateTimeFormatPartTypes) => parts.find(part => part.type === type)?.value ?? '';
 return `${get('year')}-${get('month')}-${get('day')}T${get('hour')}:${get('minute')}:${get('second')}`;
}
