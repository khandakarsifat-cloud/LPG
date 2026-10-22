import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useBatchedDirectory } from './useBatchedDirectory';
import { supabase } from '../lib/supabase';
import type { Purchase, PurchaseActivity, CreatePurchasePayload, PurchaseDraft, PurchaseSettlement } from '../types/purchase';
import type { PaymentInput } from '../types/finance';
import { PurchaseStockError, type EmptyShortage } from '../lib/purchase';
import type { PurchaseFilters } from '../lib/purchase';
import { useState } from 'react';
import { useAuth } from '../contexts/AuthContext';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';

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

export const usePurchaseOverview = () => useQuery<{ total: number; created: number; in_transit: number; unpaid: number; company_payable: number; outstanding?: number }>({
  queryKey: [...purchaseKeys.all, 'overview'],
  queryFn: async ({ signal }) => {
    const { data, error } = await supabase.rpc('get_purchase_overview').abortSignal(signal);
    if (error) throw error;
    return data as { total: number; created: number; in_transit: number; unpaid: number; company_payable: number; outstanding?: number };
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
        qc.invalidateQueries({ queryKey: ['logistics'] }), qc.invalidateQueries({ queryKey: ['finance'] }),
      ]);
    },
    onSuccess: async () => {
      await Promise.all([
        qc.invalidateQueries({ queryKey: purchaseKeys.all }), qc.invalidateQueries({ queryKey: ['inventory'] }),
        qc.invalidateQueries({ queryKey: ['logistics'] }), qc.invalidateQueries({ queryKey: ['finance'] }), qc.invalidateQueries({ queryKey: ['dashboard'] }),
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

export const useCreatePurchase = () => {
  const { profile, user } = useAuth();
  const storageKey = `lpg-purchase-pending:${profile?.tenant_id}:${user?.id}`;
  const [hasPending, setHasPending] = useState(() => hasPendingRequest(storageKey));
  const mutation = usePurchaseMutation(async (payload: Omit<CreatePurchasePayload, 'request_id'> | undefined) => {
    if (!profile || !user) throw new Error('Sign in before creating a purchase.');
    const pending = prepareRequest(storageKey, payload);
    setHasPending(true);
    const { data, error } = await supabase.rpc('create_purchase', { p_payload: { ...pending.body, request_id: pending.id } });
    if (!error || isDefiniteRejection(error.code)) {
      finishRequest(storageKey, pending.id); setHasPending(false);
    }
    if (error) throw new Error(error.message);
    return data;
  });
  return { ...mutation, hasPending };
};
export const useUpdatePurchase = () => usePurchaseMutation((payload: {
  purchase_id: string; revision: number; draft: PurchaseDraft | Pick<PurchaseDraft, 'notes'>;
}) => purchaseRpc('update_purchase', {
  p_purchase_id: payload.purchase_id, p_revision: payload.revision, p_payload: payload.draft,
}));

type Transition = { purchase_id: string; revision: number };
export const useDispatchPurchase = () => usePurchaseMutation((payload: Transition) =>
  purchaseRpc('dispatch_purchase', { p_purchase_id: payload.purchase_id, p_revision: payload.revision }));
export const useReceivePurchase = () => usePurchaseMutation((payload: Transition) =>
  purchaseRpc('receive_purchase', { p_purchase_id: payload.purchase_id, p_revision: payload.revision }));

export const usePurchaseSettlement = (id: string, page = 0) => useQuery<PurchaseSettlement>({
  queryKey: [...purchaseKeys.detail(id), 'settlement', page], refetchInterval: 30_000,
  queryFn: async ({ signal }) => {
    const { data, error } = await supabase.rpc('get_purchase_settlement', { p_purchase_id: id, p_offset: page * 10, p_limit: 10 }).abortSignal(signal);
    if (error) throw error;
    return data;
  },
});

type PurchaseOperation = { action: 'payment'; purchase_id: string; payments: PaymentInput[] }
  | { action: 'refund'; purchase_id: string; obligation_id: string; payments: PaymentInput[] }
  | { action: 'cancel'; purchase_id: string; revision: number; confirmation: string };

/** Retain the original request across response loss, dialog closure and reload. */
export function usePurchaseOperation() {
  const { profile, user } = useAuth();
  const key = `lpg-purchase-finance-pending:${profile?.tenant_id}:${user?.id}`;
  const [hasPending, setHasPending] = useState(() => hasPendingRequest(key));
  const mutation = usePurchaseMutation(async (operation: PurchaseOperation | undefined) => {
    if (!profile || !user) throw new Error('Sign in before recording a purchase transaction.');
    const request = prepareRequest(key, operation); setHasPending(true);
    const body = request.body;
    const name = body.action === 'payment' ? 'record_purchase_payment' : body.action === 'refund' ? 'refund_purchase' : 'initiate_purchase_cancellation';
    const parameters = body.action === 'cancel'
      ? { p_purchase_id: body.purchase_id, p_revision: body.revision, p_confirmation: body.confirmation, p_request_id: request.id }
      : { p_purchase_id: body.purchase_id, p_payments: body.payments, p_request_id: request.id, ...(body.action === 'refund' ? { p_obligation_id: body.obligation_id } : {}) };
    const { data, error } = await supabase.rpc(name, parameters);
    if (!error || isDefiniteRejection(error.code) || error.code === '40001') { finishRequest(key, request.id); setHasPending(false); }
    if (error) throw new Error(error.message);
    return data;
  });
  return { ...mutation, hasPending };
}
