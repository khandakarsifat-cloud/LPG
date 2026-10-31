import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';
import { useBatchedDirectory } from './useBatchedDirectory';
import type { BottleCollection, SaleBottles, SalesFilters, SaleSummary } from '../types/bottles';

export const defaultSalesFilters: SalesFilters = { status: 'completed', search: '', payment: 'all', bottles: 'all', from: '', to: '', sort: 'date_desc', tier: 'all' };
export function useSalesDirectory(filters: SalesFilters, size: number) {
 return useBatchedDirectory<SaleSummary>(['sales', 'directory', filters], size, async (offset, limit, signal) => {
  const { data, error } = await supabase.rpc('get_sales_directory', { p_filters: filters, p_offset: offset, p_limit: limit }).abortSignal(signal);
  if (error) throw error; return data;
 });
}
export function useSalesOverview() {
 return useQuery<{ total: number; amount: number; due: number; bottles: number }>({ queryKey: ['sales', 'overview'], refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_sales_overview').abortSignal(signal); if (error) throw error; return data; } });
}
export function useCustomerBottleBalance(customerId: string) {
 return useQuery<number>({ queryKey: ['sales','customer-bottle-balance',customerId], refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data,error } = await supabase.rpc('get_customer_bottle_balance',{p_customer_id:customerId}).abortSignal(signal); if (error) throw error; return Number(data); } });
}
export async function loadSaleBottles(saleId: string, page = 0, signal?: AbortSignal): Promise<SaleBottles> {
 const query = supabase.rpc('get_sale_bottles', { p_sale_id: saleId, p_offset: page * 10, p_limit: 10 });
 const { data, error } = await (signal ? query.abortSignal(signal) : query); if (error) throw error; return data;
}
export function useSaleBottles(saleId: string, page = 0) {
 return useQuery({ queryKey: ['sales', 'bottles', saleId, page], queryFn: ({ signal }) => loadSaleBottles(saleId, page, signal), refetchInterval: 30_000 });
}
/** One uncertain bottle operation per user/business/tab, recoverable from any sale. */
export function useCollectBottles() {
 const { profile, user } = useAuth(); const qc = useQueryClient();
 const key = `lpg-bottles-pending:${profile?.tenant_id}:${user?.id}`;
 // Other instances (the collection dialog, its parent and Sales) share storage.
 // Re-read on render so closing an uncertain dialog exposes recovery immediately.
 const hasPending = hasPendingRequest(key);
 const mutation = useMutation({ mutationFn: async (operation?: { sale_id: string; payload: BottleCollection }) => {
  if (!profile || !user) throw new Error('Sign in before collecting bottles.');
  const request = prepareRequest(key, operation);
  const { data, error } = await supabase.rpc('collect_sale_bottles', { p_sale_id: request.body.sale_id, p_payload: request.body.payload, p_request_id: request.id });
  if (!error || isDefiniteRejection(error.code)) finishRequest(key, request.id);
  if (error) throw new Error(error.message); return data;
 }, onSuccess: () => Promise.all([['sales'], ['inventory'], ['customers'], ['finance'], ['dashboard'], ['logistics']].map(queryKey => qc.invalidateQueries({ queryKey }))) });
 return { ...mutation, hasPending };
}
