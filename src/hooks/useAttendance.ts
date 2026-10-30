import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';
import type { AttendanceConfiguration, AttendanceDay, AttendanceLink, AttendanceOperation, AttendanceUser, AttendancePeriod, AttendanceView, AttendanceEdit, AttendanceCorrection } from '../types/attendance';

export function useAttendanceConfiguration() {
 const { profile, can } = useAuth();
 return useQuery<AttendanceConfiguration>({ queryKey: ['attendance', profile?.tenant_id, 'configuration'],
  enabled: !!profile && (can('employees:view') || can('employees:manage') || can('settings:manage')), refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_attendance_configuration').abortSignal(signal); if (error) throw error; return data; } });
}
export function useEmployeeAttendance(id: string, month: string) {
 const { profile, can } = useAuth();
 return useQuery<{ entries: AttendanceDay[]; links: AttendanceLink[] }>({ queryKey: ['attendance', profile?.tenant_id, 'employee', id, month],
  enabled: !!profile && !!id && (can('employees:view') || can('employees:manage')), refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_employee_attendance', { p_employee_id: id, p_month: month + '-01' }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useAttendanceUsers(device: string, page: number) {
 const { profile } = useAuth();
 return useQuery<{ entries: AttendanceUser[]; total: number }>({ queryKey: ['attendance', profile?.tenant_id, 'unmapped', device, page], enabled: !!device,
  refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_attendance_users', { p_device_id: device, p_offset: page * 25 }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useAttendanceOperation() {
 const cache = useQueryClient();
 return useMutation({ mutationFn: async (operation: AttendanceOperation) => {
  const response = operation.action === 'settings'
   ? await supabase.rpc('save_attendance_configuration', { p_timezone: operation.timezone, p_cutoff: operation.cutoff })
   : await supabase.rpc('save_attendance_device', { p_device_id: operation.device_id, p_serial: operation.serial, p_name: operation.name, p_action: operation.operation });
  if (response.error) throw new Error(response.error.message);
  return response.data;
 }, onSuccess: () => Promise.all([cache.invalidateQueries({ queryKey: ['attendance'] }), cache.invalidateQueries({ queryKey: ['employees'] })]) });
}
export function useAttendanceHistory(employee: string, view: AttendanceView, from: string, to: string, page: number) {
 const { profile } = useAuth();
 return useQuery<{ entries: AttendancePeriod[]; total: number }>({ queryKey: ['attendance', profile?.tenant_id, 'history', employee, view, from, to, page], refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_attendance_history', { p_employee_id: employee, p_view: view, p_from: from || null, p_to: to || null, p_offset: page * 12 }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useAttendanceEdit(employee: string, day: string) {
 const { profile } = useAuth();
 return useQuery<AttendanceEdit>({ queryKey: ['attendance', profile?.tenant_id, 'edit', employee, day], enabled: !!day, staleTime: 0,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_attendance_edit', { p_employee_id: employee, p_day: day }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useAttendanceCorrection(onSaved?: () => void) {
 const cache = useQueryClient(); const { user, profile } = useAuth();
 const key = `lpg-attendance-correction:${profile?.tenant_id}:${user?.id}`;
 const mutation = useMutation({ mutationFn: async (input?: AttendanceCorrection) => {
  if (!user || !profile) throw new Error('Sign in before correcting attendance.');
  const request = prepareRequest(key, input ? { ...input } : undefined); const body = request.body;
  if (typeof body.employee_id !== 'string' || typeof body.day !== 'string' || typeof body.clock_in !== 'string' || typeof body.clock_out !== 'string' || typeof body.reason !== 'string' || typeof body.revision !== 'number') throw new Error('The pending correction could not be read. Keep this tab open.');
  const { error } = await supabase.rpc('correct_employee_attendance', { p_employee_id: body.employee_id, p_day: body.day, p_clock_in: body.clock_in, p_clock_out: body.clock_out, p_reason: body.reason, p_revision: body.revision, p_request_id: request.id });
  if (!error || isDefiniteRejection(error.code)) finishRequest(key, request.id);
  if (error) throw new Error(error.message);
 }, onSuccess: async () => { onSaved?.(); await Promise.all([['attendance'], ['employees']].map(queryKey => cache.invalidateQueries({ queryKey }))); } });
 return { ...mutation, hasPending: hasPendingRequest(key) };
}

export function useEmployeePresence(ids: string[]) {
 const { can } = useAuth();
 return useQuery<{ timezone: string; entries: AttendanceDay[] }>({ queryKey: ['attendance','presence',ids], enabled: ids.length>0 && (can('employees:view') || can('employees:manage')), refetchInterval:30000,
 queryFn: async ({signal}) => { const {data,error}=await supabase.rpc('get_employee_presence',{p_ids:ids}).abortSignal(signal); if(error)throw error;return data; } });
}
