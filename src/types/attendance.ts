export interface AttendanceDevice {
 device_id: string; serial: string; name: string; enabled: boolean; approved: boolean;
 last_seen_at: string | null; last_upload_at: string | null; last_event_at: string | null;
 last_batch_count: number; last_ignored_count: number; registered_at: string; unmapped: number;
}
export interface AttendanceConfiguration { timezone: string; clock_out_cutoff: string; next_clock_out_cutoff: string; today: string; can_correct: boolean; devices: AttendanceDevice[] }
export interface AttendanceDay {
 employee_id: string; work_date: string; clock_in: string | null; clock_out: string | null; worked_seconds: number;
 scan_count: number; warning_count: number; timezone: string; automatic_close: boolean; manual: boolean;
 starts_at: string; ends_at: string; revision: number; updated_at: string;
}
export interface AttendanceLink { link_id: string; device_id: string; device_name: string; pin: string; linked_at: string; unlinked_at: string | null }
export interface AttendanceUser { pin: string; first_seen_at: string; last_seen_at: string }
export type AttendanceView = 'daily' | 'weekly' | 'monthly';
export interface AttendancePeriod { period: string; clock_in: string | null; clock_out: string | null; worked_seconds: number; attended_days: number; automatic_close: boolean; manual: boolean }
export interface AttendanceAdjustment { adjustment_id: string; clock_in: string | null; clock_out: string | null; reason: string; created_at: string; actor: string | null; before_values: Partial<AttendanceDay> }
export interface AttendanceEdit { window: { starts_at: string; ends_at: string; latest_at: string }; day: AttendanceDay | null; adjustments: AttendanceAdjustment[] }
export interface AttendanceCorrection { employee_id: string; day: string; clock_in: string; clock_out: string; reason: string; revision: number; request_id: string }
export type DeviceAction = 'register' | 'edit' | 'approve' | 'disable' | 'enable' | 'remove';
export type AttendanceOperation = { action: 'settings'; timezone: string; clock_out_cutoff: string }
 | { action: 'device'; device_id: string | null; serial: string; name: string; operation: DeviceAction };
