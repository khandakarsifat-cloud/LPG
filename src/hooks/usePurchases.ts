import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useBatchedDirectory } from './useBatchedDirectory';
import { supabase } from '../lib/supabase';
import type { Purchase, PurchaseActivity, CreatePurchasePayload, PurchaseDraft } from '../types/purchase';
import { PurchaseStockError, type EmptyShortage } from '../lib/purchase';
import type { PurchaseFilters } from '../lib/purchase';

export const purchaseKeys = {
  all: ['purchases'] as const,
  purchases: ['purchases', 'list'] as const,
  activity: (id: string) => ['purchases', 'activity', id] as const,
  detail: (id: string) => ['purchases', 'detail', id] as const,
};

export const usePurchases = ({ ids, enabled = true }: { ids: string[]; enabled?: boolean }) => useQuery<Purchase[]>({
  queryKey: [...purchaseKeys.purchases, ids],
  enabled: enabled && ids.length > 0,
  queryFn: async ({ signal }) => {
    const { data, error } = await supabase.rpc('get_purchases_by_ids', { p_ids: ids }).abortSignal(signal);
    if (error) throw error;
    return (data ?? []) as Purchase[];
  },
  refetchInterval: 30_000,
});

export const usePurchaseDetails = (id: string | null) => useQuery<Purchase>({
  queryKey: purchaseKeys.detail(id ?? ''), enabled: Boolean(id),
  queryFn: async ({ signal }) => {
    const { data, error } = await supabase.rpc('get_purchases_by_ids', { p_ids: [id] }).abortSignal(signal);
    if (error) throw error;
    const rows = (data ?? []) as Purchase[];
    if (!rows[0]) throw new Error('Purchase not found.');
    return rows[0];
  },
  staleTime: 0, refetchInterval: 30_000,
});

export const usePurchaseDirectory = (filters: PurchaseFilters, page: number, pageSize: number) => useBatchedDirectory<Purchase>(
  [...purchaseKeys.all, 'directory', filters], page, pageSize, async (offset, limit, signal) => {
    const { data, error } = await supabase.rpc('get_purchase_directory', { p_filters: filters, p_offset: offset, p_limit: limit }).abortSignal(signal);
    if (error) throw error;
    return data as { entries: Purchase[]; total: number };
  });

export const usePurchaseOverview = () => useQuery<{ total: number; created: number; in_transit: number; unpaid: number; company_payable: number }>({
  queryKey: [...purchaseKeys.all, 'overview'],
  queryFn: async ({ signal }) => {
    const { data, error } = await supabase.rpc('get_purchase_overview').abortSignal(signal);
    if (error) throw error;
    return data as { total: number; created: number; in_transit: number; unpaid: number; company_payable: number };
  }, refetchInterval: 30_000,
});

export const PURCHASE_ACTIVITY_PAGE_SIZE = 6;

export const usePurchaseActivity = (purchaseId: string, page: number) => useQuery({
  queryKey: [...purchaseKeys.activity(purchaseId), page],
  queryFn: async ({ signal }) => {
    // Keep the RPC's chronological order. One extra row tells us whether there
    // is another page without a separate count or downloading the full history.
    const start = page * PURCHASE_ACTIVITY_PAGE_SIZE;
    const { data, error } = await supabase.rpc('get_purchase_activity', { p_purchase_id: purchaseId })
      .range(start, start + PURCHASE_ACTIVITY_PAGE_SIZE).abortSignal(signal);
    if (error) throw error;
    const rows = (data ?? []) as PurchaseActivity[];
    return { entries: rows.slice(0, PURCHASE_ACTIVITY_PAGE_SIZE), hasMore: rows.length > PURCHASE_ACTIVITY_PAGE_SIZE };
  },
});

function usePurchaseMutation<T>(mutationFn: (payload: T) => Promise<unknown>) {
  const qc = useQueryClient();
  return useMutation<unknown, Error, T>({
    mutationFn,
    onError: async () => {
      await Promise.all([
        qc.invalidateQueries({ queryKey: purchaseKeys.all }),
        qc.invalidateQueries({ queryKey: ['inventory'] }),
        qc.invalidateQueries({ queryKey: ['logistics'] }),
      ]);
    },
    onSuccess: async () => {
      await Promise.all([
        qc.invalidateQueries({ queryKey: purchaseKeys.all }), qc.invalidateQueries({ queryKey: ['inventory'] }),
        qc.invalidateQueries({ queryKey: ['logistics'] }), qc.invalidateQueries({ queryKey: ['dashboard'] }),
      ]);
    },
  });
}

async function purchaseRpc(name: string, parameters: Record<string, unknown>) {
  const { data, error } = await supabase.rpc(name, parameters);
  if (error) {
    if (error.message === 'Not enough empty cylinders' && error.details) {
      let details: unknown;
      try { details = JSON.parse(error.details); } catch { /* Fall through to the server message. */ }
      if (Array.isArray(details) && details.every((item: unknown): item is EmptyShortage =>
        typeof item === 'object' && item !== null && 'product' in item && typeof item.product === 'string'
        && 'available' in item && typeof item.available === 'number' && 'missing' in item && typeof item.missing === 'number'
        && 'required' in item && typeof item.required === 'number' && 'item_id' in item && typeof item.item_id === 'string')) {
        throw new PurchaseStockError(details);
      }
    }
    throw new Error(error.message);
  }
  return data;
}

export const useCreatePurchase = () => usePurchaseMutation((payload: CreatePurchasePayload) =>
  purchaseRpc('create_purchase', { p_payload: payload }));
export const useUpdatePurchase = () => usePurchaseMutation((payload: {
  purchase_id: string; revision: number; draft: PurchaseDraft | Pick<PurchaseDraft, 'notes'>;
}) => purchaseRpc('update_purchase', {
  p_purchase_id: payload.purchase_id, p_revision: payload.revision, p_payload: payload.draft,
}));

type Transition = { purchase_id: string; revision: number };
export const useDispatchPurchase = () => usePurchaseMutation((payload: Transition) =>
  purchaseRpc('dispatch_purchase', { p_purchase_id: payload.purchase_id, p_revision: payload.revision }));
export const usePayPurchase = () => usePurchaseMutation((payload: Transition) =>
  purchaseRpc('pay_purchase', { p_purchase_id: payload.purchase_id, p_revision: payload.revision }));
export const useCancelPurchase = () => usePurchaseMutation((payload: Transition) =>
  purchaseRpc('cancel_purchase', { p_purchase_id: payload.purchase_id, p_revision: payload.revision }));
export const useReceivePurchase = () => usePurchaseMutation((payload: Transition) =>
  purchaseRpc('receive_purchase', { p_purchase_id: payload.purchase_id, p_revision: payload.revision }));
