import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';
import { useBatchedDirectory } from './useBatchedDirectory';
import type { ActivityFilters, Employee, EmployeeFilters, EmployeeOperation, EmployeeOverview, EmployeeProfile, EmployeeResult, EmployeeActivity, EmployeeSalaryMonth } from '../types/employee';
import type { PaymentWallet } from '../types/finance';

export const employeeKeys = ['employees'] as const;
export function useEmployeeForPayment(id: string | null) {
 return useQuery<string>({ queryKey: [...employeeKeys, 'payment-employee', id], enabled: !!id,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_employee_for_payment', { p_payment_id: id }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useTripPaymentWallets(id?: string) {
 return useQuery<PaymentWallet[]>({ queryKey: [...employeeKeys, 'trip-wallets', id], enabled: !!id,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_trip_payment_wallets', { p_transit_id: id }).abortSignal(signal); if (error) throw error; return data; } });
}
export interface TransitPayroll { driver_paid: number; helper_paid: number; paid: number }
export function useTransitPayroll(id: string) {
 return useQuery<TransitPayroll>({ queryKey: [...employeeKeys, 'transit', id], refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_transit_payroll', { p_transit_id: id }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useEmployeeDirectory(filters: EmployeeFilters, pageSize: number) {
 return useBatchedDirectory<Employee>([...employeeKeys, 'directory', filters], pageSize, async (offset, limit, signal) => {
  const { data, error } = await supabase.rpc('get_employee_directory', { p_filters: filters, p_offset: offset, p_limit: limit }).abortSignal(signal);
  if (error) throw error; return data as EmployeeResult<Employee>;
 });
}
export function useEmployeeOverview() {
 return useQuery<EmployeeOverview>({ queryKey: [...employeeKeys, 'overview'], refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_employee_overview').abortSignal(signal); if (error) throw error; return data; } });
}
export function useEmployeeProfile(id: string) {
 return useQuery<EmployeeProfile>({ queryKey: [...employeeKeys, 'profile', id], enabled: !!id, refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_employee_profile', { p_employee_id: id }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useEmployeeSalaryMonth(id: string, period: string, enabled = true) {
 return useQuery<EmployeeSalaryMonth>({ queryKey: [...employeeKeys, 'salary-month', id, period], enabled,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_employee_salary_month', { p_employee_id: id, p_period: period }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useEmployeeActivity(filters: ActivityFilters, page: number, enabled = true) {
 return useQuery<EmployeeResult<EmployeeActivity>>({ queryKey: [...employeeKeys, 'activity', filters, page], enabled, refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_employee_activity', { p_filters: filters, p_offset: page * 12, p_limit: 12 }).abortSignal(signal); if (error) throw error; return data; } });
}
/** One recoverable write across the directory and every employee dialog. */
export function useEmployeeOperation() {
 const { profile, user } = useAuth(); const qc = useQueryClient();
 const key = `lpg-employee-pending:${profile?.tenant_id}:${user?.id}`;
 const mutation = useMutation({
  mutationFn: async (operation?: EmployeeOperation) => {
   if (!profile || !user) throw new Error('Sign in before saving employee information.');
   const request = prepareRequest(key, operation); const body = request.body;
   const { data, error } = body.action === 'profile'
    ? await supabase.rpc('save_employee', { p_payload: body.profile, p_request_id: request.id })
    : await supabase.rpc('employee_payment_operation', { p_payload: body, p_request_id: request.id });
   if (!error || isDefiniteRejection(error.code)) finishRequest(key, request.id);
   if (error) throw new Error(error.message); return data;
  },
  onSuccess: () => Promise.all([employeeKeys, ['attendance'], ['finance'], ['logistics'], ['purchases']].map(queryKey => qc.invalidateQueries({ queryKey }))),
 });
 return { ...mutation, hasPending: hasPendingRequest(key) };
}
