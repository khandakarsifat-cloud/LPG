import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Purchase, CreatePurchasePayload } from '../types/purchase';

// ── Query Keys ────────────────────────────────────────────────────────────────
export const purchaseKeys = {
  all:       ['purchases']           as const,
  purchases: ['purchases', 'list']   as const,
  purchase:  (id: string) => ['purchases', 'detail', id] as const,
};

// ─────────────────────────────────────────────────────────────────────────────
// QUERIES
// ─────────────────────────────────────────────────────────────────────────────

export const usePurchases = () =>
  useQuery<Purchase[]>({
    queryKey: purchaseKeys.purchases,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_purchases');
      if (error) throw error;
      return (data ?? []) as Purchase[];
    },
    refetchInterval: 30_000,
  });

// ─────────────────────────────────────────────────────────────────────────────
// MUTATIONS
// ─────────────────────────────────────────────────────────────────────────────

export const useCreatePurchase = () => {
  const qc = useQueryClient();
  
  return useMutation<unknown, Error, CreatePurchasePayload>({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.rpc('create_purchase', {
        p_truck_id:       payload.truck_id,
        p_plant_id:       payload.plant_id,
        p_transport_cost: payload.transport_cost,
        p_labour_cost:    payload.labour_cost,
        p_notes:          payload.notes ?? null,
        p_items:          payload.items,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: purchaseKeys.purchases });
      qc.invalidateQueries({ queryKey: ['inventory', 'balances'] });
      qc.invalidateQueries({ queryKey: ['inventory', 'movements'] });
      qc.invalidateQueries({ queryKey: ['logistics', 'trucks'] });
      qc.invalidateQueries({ queryKey: ['logistics', 'wallets'] });
      qc.invalidateQueries({ queryKey: ['dashboard'] });
    },
  });
};

export const useUpdatePurchase = () => {
  const qc = useQueryClient();
  
  return useMutation<unknown, Error, { purchase_id: string, transport_cost: number, labour_cost: number, notes: string, items: { item_id: string, unit_price: number, quantity: number }[] }>({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.rpc('update_purchase', {
        p_purchase_id:    payload.purchase_id,
        p_transport_cost: payload.transport_cost,
        p_labour_cost:    payload.labour_cost,
        p_notes:          payload.notes,
        p_items:          payload.items,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: purchaseKeys.purchases });
      qc.invalidateQueries({ queryKey: ['logistics', 'wallets'] });
    },
  });
};

export const useCompletePurchase = () => {
  const qc = useQueryClient();
  
  return useMutation<unknown, Error, string>({
    mutationFn: async (purchaseId) => {
      const { data, error } = await supabase.rpc('complete_purchase', {
        p_purchase_id: purchaseId,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: purchaseKeys.purchases });
      qc.invalidateQueries({ queryKey: ['inventory', 'balances'] });
      qc.invalidateQueries({ queryKey: ['inventory', 'movements'] });
      qc.invalidateQueries({ queryKey: ['logistics', 'wallets'] });
      qc.invalidateQueries({ queryKey: ['logistics', 'transits'] });
      qc.invalidateQueries({ queryKey: ['dashboard'] });
    },
  });
};
