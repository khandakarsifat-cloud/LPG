import { invalidateFreshQueries } from '../lib/invalidateFreshQueries';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { BusinessAllocation, FinancialCatalog } from '../types/financial';

export function useFinancialCatalog() {
 return useQuery<FinancialCatalog>({ queryKey: ['finance', 'type-catalog'], staleTime: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_financial_catalog').abortSignal(signal); if (error) throw error; return data; } });
}

export function useSaveFinancialType() {
 const qc = useQueryClient();
 return useMutation({ mutationFn: async (payload: { type_id?: string; revision?: number; name: string; account: string; allocations: BusinessAllocation; is_active: boolean }) => {
  const { data, error } = await supabase.rpc('save_financial_type', { p_payload: payload }); if (error) throw error; return data;
 }, onSuccess: () => invalidateFreshQueries(qc, { queryKey: ['finance'] }) });
}

export interface FinancialEntry {
 entry_id: string; type_id: string; type_name: string; type_revision: number; account: string;
 allocations: BusinessAllocation; wallet_id: string; wallet_name: string; amount: number;
 occurred_on: string; description: string; returned: number; reversal_of: string | null; asset_id: string | null;
}
export function useFinancialEntry(id: string) {
 return useQuery<FinancialEntry>({ queryKey: ['finance', 'financial-entry', id],
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_financial_entry', { p_entry_id: id }).abortSignal(signal); if (error) throw error; return data; } });
}
export interface FinancialEntryFilters { search: string; category: string; business: string; from: string; to: string }
export function useFinancialEntries(filters: FinancialEntryFilters, page: number) {
 return useQuery<{ total: number; entries: FinancialEntry[] }>({ queryKey: ['finance', 'financial-entries', filters, page],
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_financial_entries', { p_filters: filters, p_offset: page * 25, p_limit: 25 }).abortSignal(signal); if (error) throw error; return data; } });
}
