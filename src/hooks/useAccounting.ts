import { invalidateFreshQueries } from '../lib/invalidateFreshQueries';
import { stockDisplay } from '../lib/stockDisplay';
import { useState } from 'react';
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { readAllRows } from '../lib/queryPages';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';
import type { AccountingBreakdownEntry, AccountingCommand, BusinessAsset, CostEntry, CostPool, InventoryAdjustment, JournalEntry, JournalLine, JournalFilters, JournalReport, Loan, OpeningBalance, StoveProduct, StoveType } from '../types/accounting';
import type { AccountingBreakdown, AnalysisGroup, AnalysisSide } from '../types/accounting';
import type { ItemWithBrand } from '../types/inventory';

export function useAccountingBreakdown(filters: JournalFilters, group: AnalysisGroup, side: AnalysisSide, mode: 'components' | 'history', page: number, enabled = true) {
 return useQuery<AccountingBreakdown>({ enabled, queryKey: ['finance', 'breakdown', filters, group, side, mode, page], placeholderData: keepPreviousData, staleTime: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_accounting_breakdown', { p_filters: filters, p_group: group, p_side: side, p_mode: mode, p_offset: page * 20, p_limit: 20 }).abortSignal(signal); if (error) throw error; return data; } });
}
export function useAccountingHealth(filters: JournalFilters, page: number) {
 return useQuery<{ pending: number; snapshots: number; total: number; entries: { finding_id: number; kind: string; entity_id: string; status: string; diagnostic: string; recorded_at: string; expected: Record<string, unknown>; observed: Record<string, unknown> }[] }>({ queryKey: ['finance', 'accounting-health', filters.business_id, page], staleTime: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_accounting_health', { p_filters: filters, p_offset: page * 20 }).abortSignal(signal); if (error) throw error; return data; } });
}
type AccountingProduct = (ItemWithBrand & { business_category: 'lpg' }) | StoveProduct;
export function useAccountingProduct(id: string | null) {
 return useQuery<AccountingProduct>({ queryKey: ['inventory', 'analysis-product', id], enabled: Boolean(id),
  queryFn: async ({ signal }) => { const { data, error } = await supabase.from('items').select('*,lpg_brands(brand_id,brand_name)').eq('item_id', id).limit(1).abortSignal(signal).overrideTypes<(AccountingProduct)[], { merge: false }>(); if (error) throw error; if (!data?.[0]) throw new Error('Product not found'); return stockDisplay(data[0]); } });
}

function useAccountingWrite<T extends object>(rpc: string, scope: string) {
 const { profile, user } = useAuth(); const qc = useQueryClient(); const key = `lpg-${scope}:${profile?.tenant_id}:${user?.id}`;
 const [pending, setPending] = useState(() => hasPendingRequest(key));
 const mutation = useMutation<{ id?: string; item_id?: string }, Error, T | undefined>({ mutationFn: async payload => {
  if (!profile || !user) throw new Error('Sign in before recording this operation.');
  const request = prepareRequest(key, payload ? Object.fromEntries(Object.entries(payload)) : undefined); setPending(true);
  const { data, error } = await supabase.rpc(rpc, { p_payload: request.body, p_request_id: request.id });
  if (!error || isDefiniteRejection(error.code)) { finishRequest(key, request.id); setPending(false); }
  if (error) throw new Error(error.message); return data;
 }, onSuccess: () => Promise.all([['inventory'], ['finance'], ['logistics'], ['purchases'], ['sales'], ['customers'], ['dashboard'], ['price_books']].map(queryKey => invalidateFreshQueries(qc, { queryKey }))) });
 return { ...mutation, hasPending: pending };
}
export const useAccountingOperation = () => useAccountingWrite<AccountingCommand>('accounting_operation', 'accounting-operation');
export const useInventoryAdjustment = () => useAccountingWrite<InventoryAdjustment>('adjust_inventory', 'valued-stock-adjustment');
export const useSaveStoveProduct = () => useAccountingWrite<{ item_id?: string; name: string; type_id: string; image_url?: string | null }>('save_stove_product', 'stove-product');
export function useStoveProducts(enabled = true) { return useQuery<StoveProduct[]>({ queryKey: ['inventory', 'stove'], enabled, refetchInterval: 30_000, queryFn: async ({ signal }) => (await readAllRows<StoveProduct>((from, to) => supabase.from('items').select('*').eq('business_category', 'stove').order('product_name').order('item_id').range(from, to).abortSignal(signal).overrideTypes<StoveProduct[], { merge: false }>())).map(stockDisplay) }); }
export function useStoveTypes() { return useQuery<StoveType[]>({ queryKey: ['inventory', 'stove-types'], queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_stove_product_types').abortSignal(signal); if (error) throw error; return data; } }); }
export function useSaveStoveType() {
 const qc = useQueryClient();
 return useMutation({ mutationFn: async (p: { name: string; type_id?: string; active: boolean }) => {
  const { error } = await supabase.rpc('save_stove_product_type', { p_name: p.name, p_type_id: p.type_id ?? null, p_active: p.active });
  if (error) throw new Error(error.message);
 }, onSuccess: async () => {
  const keys = [['inventory', 'stove-types'], ['dashboard']];
  await Promise.all(keys.map(queryKey => invalidateFreshQueries(qc, { queryKey })));
 } });
}
export function useInventoryCosts(itemId: string, page = 0) { return useQuery<{ pool: CostPool | null; total: number; entries: CostEntry[] }>({ queryKey: ['inventory', 'costs', itemId, page], queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_inventory_cost_history', { p_item_id: itemId, p_offset: page * 10 }).abortSignal(signal); if (error) throw error; return data; } }); }
export function useJournalReport(filters: JournalFilters) { return useQuery<JournalReport>({ queryKey: ['finance', 'journal-report', filters], enabled: Boolean(filters.from && filters.to && filters.from <= filters.to), staleTime: 30_000, placeholderData: keepPreviousData, queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_finance_analysis', { p_filters: filters }).abortSignal(signal); if (error) throw error; return data; } }); }
export function useJournalEntries(filters: JournalFilters, page: number) { return useQuery<{ total: number; entries: JournalEntry[]; sources: string[] }>({ queryKey: ['finance', 'journal', filters, page], queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_analysis_details', { p_filters: filters, p_metric: 'journal', p_category: filters.account || null, p_offset: page * 12 }).abortSignal(signal); if (error) throw error; return data; } }); }
export function useAccountingRegister<T extends Loan | BusinessAsset | OpeningBalance>(kind: 'loans' | 'lending' | 'assets' | 'opening' | 'obligations', page: number) { return useQuery<{ total: number; entries: T[] }>({ queryKey: ['finance', 'register', kind, page], refetchInterval: 30_000, queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_accounting_register', { p_kind: kind, p_offset: page * 20 }).abortSignal(signal); if (error) throw error; return data; } }); }
export function useAccountingHistory(kind: 'loan' | 'asset' | 'vehicle', id: string, page: number) { return useQuery<{ total: number; entries: Record<string, unknown>[] }>({ queryKey: ['finance', 'accounting-history', kind, id, page], queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_accounting_history', { p_kind: kind, p_id: id, p_offset: page * 20 }).abortSignal(signal); if (error) throw error; return data; } }); }

export function useJournalLines(filters: JournalFilters, journalId: string, page: number) {
 return useQuery<{ total: number; entries: JournalLine[] }>({ queryKey: ['finance', 'journal-lines', filters.business_id, journalId, page], placeholderData: keepPreviousData, queryFn: async ({ signal }) => {
  const { data, error } = await supabase.rpc('get_journal_lines', { p_filters: filters, p_journal_id: journalId, p_offset: page * 25, p_limit: 25 }).abortSignal(signal); if (error) throw error; return data;
 } });
}

export function useCanOpenAccountingRecord() {
 const { profile,can }=useAuth();
 return function canOpen(row: AccountingBreakdownEntry) {
  if (profile?.tenant_id !== row.tenant_id || !row.record_id) return false;
  return row.record_kind === 'financial_entry' ? can('finance:entries:view') : (row.record_kind === 'transit' || row.record_kind === 'service_trip') ? can('logistics:view') || can('logistics:manage') : row.record_kind === 'customer' ? can('customers:view') || can('customers:manage') : row.record_kind === 'sale' ? can('sales:view') || can('dashboard:view') : row.record_kind === 'purchase' ? can('purchases:view') || can('purchases:manage') : row.record_kind === 'product' ? can('inventory:view') || can('inventory:manage') : row.record_kind === 'employee' ? can('employees:view') || can('employees:manage') : row.record_kind === 'loan' ? can('finance:loans') : row.record_kind === 'asset' && can('finance:assets:manage');
 }

}
