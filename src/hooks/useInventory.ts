import { invalidateFreshQueries } from '../lib/invalidateFreshQueries';
import { readAllRows } from '../lib/queryPages';
import { useState } from 'react';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';
import type { Item, ItemWithBrand, InventoryMovement, CreateItemPayload } from '../types/inventory';
import type { ProductInventory, SaveProductPrices } from '../types/inventory';
import type { InventoryValuation } from '../types/inventory';
import type { BuyingPrice, BuyingComponent } from '../types/inventory';
import { posKeys } from './usePOS';
import type { InventoryHistorySource } from '../lib/inventoryMovement';

// ── Query Keys ────────────────────────────────────────────────────────────────
export const inventoryKeys = {
  all:          ['inventory']                              as const,
  balances:     ['inventory', 'balances']                  as const,
  movements:    ['inventory', 'movements']                 as const,
  movement:     (id: string) => ['inventory', 'movements', id] as const,
  itemMovements:(id: string) => ['inventory', 'movements', 'item', id] as const,
  product: (id: string) => ['inventory', 'product', id] as const,
};

// ─────────────────────────────────────────────────────────────────────────────
// QUERIES
// ─────────────────────────────────────────────────────────────────────────────

/** Inventory balances — simply fetches all items, as they now contain filled_quantity and empty_quantity */
export const useInventoryBalances = () =>
  useQuery<ItemWithBrand[]>({
    queryKey: inventoryKeys.balances,
    queryFn: async ({ signal }) => readAllRows<ItemWithBrand>((from, to) => supabase
      .from('items').select('*, lpg_brands(brand_id, brand_name)').eq('business_category', 'lpg')
      .order('brand_id', { ascending: true }).order('item_id', { ascending: true })
      .range(from, to).abortSignal(signal).overrideTypes<ItemWithBrand[], { merge: false }>()),
    refetchInterval: 30_000,
  });

export const INVENTORY_HISTORY_PAGE_SIZE = 10;
export const useInventoryHistory = ({ source, itemIds, page, from, to }: {
  source: InventoryHistorySource; itemIds: string[] | null; page: number; from: string; to: string;
}) => {
  const { can } = useAuth();
  const canReadSales = can('sales:view') || can('receipts:print');
  return useQuery<{ entries: Array<InventoryMovement & { saleCustomer: string | null }>; hasMore: boolean }>({
    queryKey: [...inventoryKeys.movements, 'history', source, itemIds ? [...itemIds].sort() : null, from, to, page, canReadSales],
    queryFn: async ({ signal }) => {
      if (itemIds?.length === 0) return { entries: [], hasMore: false };
      const { data, error } = await supabase.rpc('get_inventory_history', {
        p_filters: { source, item_ids: itemIds, from, to },
        p_offset: page * INVENTORY_HISTORY_PAGE_SIZE, p_limit: INVENTORY_HISTORY_PAGE_SIZE,
      }).abortSignal(signal);
      if (error) throw error;
      return data;
    },
    refetchInterval: 15_000,
  });
};

// ─────────────────────────────────────────────────────────────────────────────
// MUTATIONS
// ─────────────────────────────────────────────────────────────────────────────

/** Create a new product item */
export const useCreateItem = () => {
  const { profile } = useAuth();
  const qc = useQueryClient();
  return useMutation<Item, Error, CreateItemPayload>({
    mutationFn: async (payload) => {
      if (!profile) throw new Error('No tenant found');

      const { data, error } = await supabase
        .from('items')
        .insert({ ...payload, tenant_id: profile.tenant_id })
        .select()
        .single();

      if (error) throw error;
      return data as Item;
    },
    onSuccess: () => {
      invalidateFreshQueries(qc, { queryKey: inventoryKeys.balances });
    },
  });
};

export const useProductInventory = (itemId: string) => useQuery<ProductInventory>({
  queryKey: inventoryKeys.product(itemId),
  queryFn: async ({ signal }) => {
    const { data, error } = await supabase.rpc('get_product_inventory', { p_item_id: itemId }).abortSignal(signal);
    if (error) throw error;
    return data as ProductInventory;
  },
  refetchInterval: 30_000,
});

export const useSaveProductPrices = () => {
  const qc = useQueryClient();
  return useMutation<void, Error, SaveProductPrices>({
    mutationFn: async ({ itemId, tier, prices, expected }) => {
      const { error } = await supabase.rpc('save_product_prices', {
        p_item_id: itemId, p_customer_tier: tier, p_prices: prices, p_expected: expected,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await Promise.all([
        invalidateFreshQueries(qc, { queryKey: inventoryKeys.all }),
        invalidateFreshQueries(qc, { queryKey: posKeys.priceBooks }),
      ]);
    },
  });
};

export const useInventoryValuation = () => useQuery<InventoryValuation>({ queryKey: ['inventory','valuation'],refetchInterval:30_000,queryFn:async({signal})=>{
  const {data,error}=await supabase.rpc('get_inventory_valuation').abortSignal(signal);if(error)throw error;return data;
}});

export function useOperationalPriceHistory(itemId: string, page: number, enabled: boolean) {
  return useQuery<{ total: number; entries: BuyingPrice[] }>({
    queryKey: ['inventory', 'operational-price-history', itemId, page], enabled,
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase.rpc('get_buying_price_history', { p_item_id: itemId, p_offset: page * 10, p_limit: 10 }).abortSignal(signal);
      if (error) throw error; return data;
    },
  });
}
export function useSetBuyingPrice() {
  const { profile, user } = useAuth(); const qc = useQueryClient();
  const key = `lpg-buying-price:${profile?.tenant_id}:${user?.id}`;
  const [pending, setPending] = useState(() => hasPendingRequest(key));
  const mutation = useMutation({ mutationFn: async (payload: { item_id: string; price_type: BuyingComponent; is_manual: boolean; price?: number; reason: string; expected: string | null } | undefined) => {
    if (!profile || !user) throw new Error('Sign in before saving prices.');
    const request = prepareRequest(key, payload); setPending(true);
    const { error } = await supabase.rpc('set_product_buying_price', { p_payload: request.body, p_request_id: request.id });
    if (!error || isDefiniteRejection(error.code)) { finishRequest(key, request.id); setPending(false); }
    if (error) throw new Error(error.message);
  }, onSuccess: () => invalidateFreshQueries(qc, { queryKey: inventoryKeys.all }) });
  return { ...mutation, hasPending: pending };
}
