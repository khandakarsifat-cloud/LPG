import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Purchase, PurchaseActivity, CreatePurchasePayload, PurchaseDraft } from '../types/purchase';

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

export const usePurchaseActivity = (purchaseId: string) => useQuery<PurchaseActivity[]>({
  queryKey: purchaseKeys.activity(purchaseId),
  queryFn: async () => {
    const { data, error } = await supabase.rpc('get_purchase_activity', { p_purchase_id: purchaseId });
    if (error) throw error;
    return (data ?? []) as PurchaseActivity[];
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
  if (error) throw new Error(error.message);
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
export const useReceivePurchase = () => usePurchaseMutation((payload: Transition & {
  items: { purchase_item_id: string; received_quantity: number }[]; receipt_notes: string;
}) => purchaseRpc('receive_purchase', {
  p_purchase_id: payload.purchase_id, p_revision: payload.revision, p_items: payload.items, p_receipt_notes: payload.receipt_notes,
}));
