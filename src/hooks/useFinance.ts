import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';
import type { FinanceDues, FinanceWallet, LedgerFilters, PaymentInput, PaymentWallet, SaleSettlement, WalletLedger } from '../types/finance';

export const financeKeys = ['finance'] as const;
export const usePaymentWallets = (enabled = true) => useQuery<PaymentWallet[]>({
  queryKey: [...financeKeys, 'payment_wallets'], enabled,
  refetchInterval: 30_000,
  queryFn: async () => { const { data, error } = await supabase.rpc('get_payment_wallets'); if (error) throw error; return data; },
});
export const useWalletLedger = (filters: LedgerFilters, page: number, enabled = true) => useQuery<WalletLedger>({
  queryKey: [...financeKeys, 'ledger', filters, page], enabled, refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_wallet_ledger', { p_filters: filters, p_offset: page * 25, p_limit: 25 }).abortSignal(signal); if (error) throw error; return data; },
});
export const useFinanceDues = (search: string, page = 0, customerId?: string, enabled = true) => useQuery<FinanceDues>({
  queryKey: [...financeKeys, 'dues', search, page, customerId], enabled,
  refetchInterval: 30_000,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_finance_dues', { p_search: search, p_customer_id: customerId ?? null, p_offset: page * 25, p_limit: 25 }).abortSignal(signal); if (error) throw error; return data; },
});
export async function loadSaleSettlement(saleId: string, page = 0, signal?: AbortSignal): Promise<SaleSettlement> {
  const query = supabase.rpc('get_sale_settlement', { p_sale_id: saleId, p_offset: page * 10, p_limit: 10 });
  const { data, error } = await (signal ? query.abortSignal(signal) : query);
  if (error) throw error;
  if (!data) throw new Error('Sale settlement unavailable.');
  return data;
}
export const useSaleSettlement = (saleId: string | null, page = 0) => useQuery<SaleSettlement>({
  queryKey: [...financeKeys, 'settlement', saleId, page], enabled: Boolean(saleId),
  refetchInterval: 30_000,
  queryFn: ({ signal }) => { if (!saleId) throw new Error('No sale selected.'); return loadSaleSettlement(saleId, page, signal); },
});
export const useCustomerBalance = (id: string, enabled: boolean) => useQuery<number>({
  queryKey: [...financeKeys, 'customer_balance', id], enabled,
  queryFn: async () => { const { data, error } = await supabase.rpc('get_customer_balance', { p_customer_id: id }); if (error) throw error; return Number(data); },
});
export function useFinanceRefresh() {
  const qc = useQueryClient();
  return () => Promise.all([financeKeys, ['logistics'], ['customers'], ['sales'], ['dashboard']].map(queryKey => qc.invalidateQueries({ queryKey })));
}
export function useSaveFinanceWallet() {
  const refresh = useFinanceRefresh();
  return useMutation({
    mutationFn: async (wallet: Pick<FinanceWallet, 'name' | 'kind' | 'details' | 'is_active'> & { wallet_id?: string; revision?: number }) => {
      const { data, error } = await supabase.rpc('save_finance_wallet', { p_payload: wallet }); if (error) throw error; return data;
    }, onSuccess: refresh,
  });
}
export type FinanceOperation = { action:'spending'; category_id:string;category_name:string;classification:'cost'|'withdrawal';wallet_id:string;amount:number;spending_date:string;description:string } | { action: 'collection'; sale_id: string; payments: PaymentInput[] } |
  { action: 'transfer' | 'adjustment'; wallet_id: string; destination_id?: string; amount: number; reason: string };
/** One recoverable request per user/tab across Finance and customer dialogs. */
export function useFinanceOperation() {
  const { profile, user } = useAuth(); const refresh = useFinanceRefresh();
  const key = `lpg-finance-pending:${profile?.tenant_id}:${user?.id}`;
  const hasPending = hasPendingRequest(key);
  const mutation = useMutation({
    mutationFn: async (operation?: FinanceOperation) => {
      if (!profile || !user) throw new Error('Sign in before recording a payment.');
      const request = prepareRequest(key, operation);
      const body = request.body;
      const result = body.action === 'collection'
        ? await supabase.rpc('collect_sale_payment', { p_sale_id: body.sale_id, p_payments: body.payments, p_request_id: request.id })
        : body.action === 'spending' ? await supabase.rpc('record_spending',{p_payload:body,p_request_id:request.id})
        : await supabase.rpc('move_wallet_money', { p_payload: body, p_request_id: request.id });
      if (!result.error || isDefiniteRejection(result.error.code)) finishRequest(key, request.id);
      if (result.error) throw new Error(result.error.message);
      return result.data;
    }, onSuccess: refresh,
  });
  return { ...mutation, hasPending };
}

export interface SpendingCategory {category_id:string;name:string;classification:'cost'|'withdrawal';is_active:boolean;revision:number}
export interface SpendingEntry {spending_id:string;category_name:string;classification:'cost'|'withdrawal';amount:number;wallet_name:string;spending_date:string;description:string}
export function useSpendingCategories(){return useQuery<SpendingCategory[]>({queryKey:['finance','spending-categories'],queryFn:async()=>{const {data,error}=await supabase.rpc('get_spending_categories');if(error)throw error;return data;}});}
export function useSaveSpendingCategory(){const qc=useQueryClient();return useMutation({mutationFn:async(payload:{name:string;classification:'cost'|'withdrawal';category_id?:string;revision?:number;is_active?:boolean})=>{const {data,error}=await supabase.rpc('save_spending_category',{p_payload:payload});if(error)throw error;return data;},onSuccess:()=>qc.invalidateQueries({queryKey:['finance','spending-categories']})});}
export function useSpendings(filters:{search:string;classification:string;category_id:string;from:string;to:string},page:number){return useQuery<{entries:SpendingEntry[];total:number;costs:number;withdrawals:number}>({queryKey:['finance','spendings',filters,page],refetchInterval:30000,queryFn:async({signal})=>{const {data,error}=await supabase.rpc('get_spendings',{p_filters:filters,p_offset:page*12,p_limit:12}).abortSignal(signal);if(error)throw error;return data;}});}
