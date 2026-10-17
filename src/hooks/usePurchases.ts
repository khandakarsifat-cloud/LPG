import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Purchase, PurchaseActivity, CreatePurchasePayload, PurchaseDraft } from '../types/purchase';
import { PurchaseStockError, type EmptyShortage } from '../lib/purchase';

export const purchaseKeys = {
  all: ['purchases'] as const,
  purchases: ['purchases', 'list'] as const,
  activity: (id: string) => ['purchases', 'activity', id] as const,
};

export const usePurchases = () => useQuery<Purchase[]>({
  queryKey: purchaseKeys.purchases,
  queryFn: async () => {
    const { data, error } = await supabase.rpc('list_purchases');
    if (error) throw error;
    return (data ?? []) as Purchase[];
  },
  refetchInterval: 30_000,
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
