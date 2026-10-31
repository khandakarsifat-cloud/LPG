import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { readAllRows } from '../lib/queryPages';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';
import { useBatchedDirectory } from './useBatchedDirectory';
import type { AdditionalCost, Assignment, LogisticsFilters, LogisticsSummary, Transit, Vehicle, VehicleInput, Wallet } from '../types/logistics';

export const logisticsKeys = { all: ['logistics'] as const };
export const useWallets = () => useQuery<Wallet[]>({ queryKey: ['logistics', 'wallets'], refetchInterval: 30_000,
 queryFn: async () => { const { data, error } = await supabase.from('wallets').select('*').order('created_at').order('wallet_id'); if (error) throw error; return data ?? []; } });
export const useVehicles = () => useQuery<Vehicle[]>({ queryKey: ['logistics', 'vehicles', 'catalog'],
 queryFn: ({ signal }) => readAllRows<Vehicle>((from, to) => supabase.rpc('list_vehicles').range(from, to).abortSignal(signal)) });
export function useVehicleDirectory(filters: { search: string; status: string }, pageSize: number) {
 return useBatchedDirectory<Vehicle>(['logistics', 'vehicles', 'directory', filters], pageSize, async (offset, limit, signal) => {
  const { data, error } = await supabase.rpc('get_vehicle_directory', { p_filters: filters, p_offset: offset, p_limit: limit }).abortSignal(signal); if (error) throw error; return data;
 });
}
export function useVehicle(id: string | null) {
 return useQuery<Vehicle>({ queryKey: ['logistics', 'vehicle', id], enabled: !!id, refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_vehicle', { p_vehicle_id: id }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useTransit(id: string | null) {
 return useQuery<Transit>({ queryKey: ['logistics', 'transit', id], enabled: !!id, refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_transit', { p_transit_id: id }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useTransitDirectory(filters: LogisticsFilters, pageSize: number) {
 return useBatchedDirectory<Transit>(['logistics', 'transits', filters], pageSize, async (offset, limit, signal) => {
  const { data, error } = await supabase.rpc('get_transit_directory', { p_filters: filters, p_offset: offset, p_limit: limit }).abortSignal(signal); if (error) throw error; return data;
 });
}
export function useAssignments(filters: LogisticsFilters, page: number) {
 return useQuery<{ entries: Assignment[]; total: number }>({ queryKey: ['logistics', 'assignments', filters, page], refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_vehicle_assignments', { p_filters: filters, p_offset: page * 8, p_limit: 8 }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useLogisticsSummary(vehicleId?: string, employeeId?: string) {
 return useQuery<LogisticsSummary>({ queryKey: ['logistics', 'summary', vehicleId, employeeId], refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_logistics_summary', { p_vehicle_id: vehicleId ?? null, p_employee_id: employeeId ?? null }).abortSignal(signal); if (error) throw error; return data; } });
}
type LogisticsOperation = { action: 'availability'; payload: { vehicle_id: string; available: boolean; reason: string } } | { action: 'vehicle'; payload: VehicleInput } | { action: 'custom'; payload: { vehicle_id: string; fee: number; client_name: string; destination: string; description: string } };
/** Financial creation and assignment edits survive a lost response. */
export function useLogisticsOperation() {
 const { profile, user } = useAuth(); const qc = useQueryClient(); const key = `lpg-logistics-pending:${profile?.tenant_id}:${user?.id}`;
 const mutation = useMutation({ mutationFn: async (operation?: LogisticsOperation) => {
  if (!profile || !user) throw new Error('Sign in before saving Logistics details.');
  const request = prepareRequest(key, operation);
  const payload = request.body.payload;
  const availability = typeof payload === 'object' && payload !== null && 'vehicle_id' in payload && 'available' in payload && 'reason' in payload ? payload : null;
  if (request.body.action === 'availability' && !availability) throw new Error('Saved availability request is invalid');
  const { data, error } = request.body.action === 'availability' ? await supabase.rpc('set_vehicle_availability', { p_vehicle_id: availability?.vehicle_id, p_available: availability?.available, p_reason: availability?.reason, p_request_id: request.id }) : await supabase.rpc(request.body.action === 'vehicle' ? 'save_vehicle' : 'create_custom_transit', { p_payload: request.body.payload, p_request_id: request.id });
  if (!error || isDefiniteRejection(error.code)) finishRequest(key, request.id);
  if (error) throw new Error(error.message); return data;
 }, onSuccess: () => Promise.all([['logistics'], ['employees'], ['purchases'], ['finance']].map(queryKey => qc.invalidateQueries({ queryKey }))) });
 return { ...mutation, hasPending: hasPendingRequest(key) };
}
export function useUpdateTransitCosts() {
 const qc = useQueryClient();
 return useMutation({ mutationFn: async (p: { transitId: string; revision: number; driverCost: number; helperCost: number; oilCost: number; othersCost: number; additionalCosts: AdditionalCost[] }) => {
  const { data, error } = await supabase.rpc('save_transit_costs', { p_transit_id: p.transitId, p_revision: p.revision, p_costs: { driver_cost: p.driverCost, helper_cost: p.helperCost, oil_cost: p.oilCost, others_cost: p.othersCost, additional_costs: p.additionalCosts } }); if (error) throw new Error(error.message); return data;
 }, onSettled: () => Promise.all([['finance'], ['logistics'], ['purchases'], ['employees']].map(queryKey => qc.invalidateQueries({ queryKey }))) });
}
export function useTransitionTransit() {
 const qc = useQueryClient();
 return useMutation({ mutationFn: async (p: { transitId: string; revision: number; action: 'complete' | 'cancel' | 'return' }) => {
  const { data, error } = await supabase.rpc('transition_transit', { p_transit_id: p.transitId, p_action: p.action, p_revision: p.revision }); if (error) throw new Error(error.message); return data;
 }, onSettled: () => Promise.all([['logistics'], ['purchases'], ['finance'], ['employees']].map(queryKey => qc.invalidateQueries({ queryKey }))) });
}

export function useCrewOptions(role:'Driver'|'Helper'){return useQuery<{employee_id:string;name:string}[]>({queryKey:['employees','crew-options',role],queryFn:({signal})=>readAllRows<{employee_id:string;name:string}>((from,to)=>supabase.rpc('get_vehicle_crew_options',{p_role:role}).range(from,to).abortSignal(signal))});}
