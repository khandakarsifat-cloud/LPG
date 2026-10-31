import { readAllRows } from '../lib/queryPages';
import { useState } from 'react';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';
import type { Item, ItemWithBrand, InventoryMovement, CreateItemPayload } from '../types/inventory';
import type { ProductInventory, SaveProductPrices, SetProductCommission } from '../types/inventory';
import type { InventoryValuation } from '../types/inventory';
import type { BuyingPrice, CommissionHistory, PriceType } from '../types/inventory';
import { posKeys } from './usePOS';
import { inventoryHistoryBounds, inventoryMovementSource, PURCHASE_MOVEMENT_FILTER, SALE_MOVEMENT_FILTER, type InventoryHistorySource } from '../lib/inventoryMovement';

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
  const canReadSales = can('sales:view') || can('receipts:print') || can('dashboard:view');
  return useQuery({
    queryKey: [...inventoryKeys.movements, 'history', source, itemIds ? [...itemIds].sort() : null, from, to, page, canReadSales],
    queryFn: async ({ signal }) => {
      if (itemIds?.length === 0) return { entries: [], hasMore: false };
      let query = supabase.from('inventory_movements')
        .select('*, items(product_name, size_kg, filled_quantity, empty_quantity, mouth_size, lpg_brands(brand_id, brand_name)), user_profiles(email)')
        .order('created_at', { ascending: false }).order('movement_id', { ascending: false });
      if (source === 'sale') query = query.or(SALE_MOVEMENT_FILTER);
      if (source === 'purchase') query = query.or(PURCHASE_MOVEMENT_FILTER);
      if (itemIds) query = query.in('item_id', itemIds);
      const { since, until } = inventoryHistoryBounds(from, to);
      if (since) query = query.gte('created_at', since);
      if (until) query = query.lt('created_at', until);
      const start = page * INVENTORY_HISTORY_PAGE_SIZE;
      const { data, error } = await query.range(start, start + INVENTORY_HISTORY_PAGE_SIZE).abortSignal(signal);
      if (error) throw error;
      const rows = (data ?? []) as InventoryMovement[];
      const visible = rows.slice(0, INVENTORY_HISTORY_PAGE_SIZE);
      const saleIds = [...new Set(visible.flatMap(movement => {
        const ref = inventoryMovementSource(movement);
        return ref.kind === 'sale' && ref.id ? [ref.id] : [];
      }))];
      const names = new Map<string, string | null>();
      if (canReadSales && saleIds.length) {
        const sales = await supabase.from('sales').select('sale_id, customers(name)')
          .in('sale_id', saleIds).abortSignal(signal)
          .overrideTypes<Array<{ sale_id: string; customers: { name: string } | null }>, { merge: false }>();
        if (sales.error) throw sales.error;
        for (const sale of sales.data ?? []) names.set(sale.sale_id, sale.customers?.name ?? null);
      }
      return { entries: visible.map(movement => ({ ...movement, saleCustomer: names.get(movement.reference_id ?? '') ?? null })), hasMore: rows.length > INVENTORY_HISTORY_PAGE_SIZE };
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
      qc.invalidateQueries({ queryKey: inventoryKeys.balances });
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
        qc.invalidateQueries({ queryKey: inventoryKeys.all }),
        qc.invalidateQueries({ queryKey: posKeys.priceBooks }),
      ]);
    },
  });
};

export const useSetProductCommission = () => {
  const qc = useQueryClient();
  return useMutation<void, Error, SetProductCommission>({
    mutationFn: async ({ itemId, refillRate, packageRate, expected }) => {
      const { error } = await supabase.rpc('set_product_commissions', {
        p_item_id: itemId, p_refill_rate: refillRate, p_package_rate: packageRate, p_expected: expected,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => { await Promise.all([qc.invalidateQueries({ queryKey: inventoryKeys.all }),qc.invalidateQueries({ queryKey: ['finance'] })]); },
  });
};

export const useInventoryValuation = () => useQuery<InventoryValuation>({ queryKey: ['inventory','valuation'],refetchInterval:30_000,queryFn:async({signal})=>{
  const {data,error}=await supabase.rpc('get_inventory_valuation').abortSignal(signal);if(error)throw error;return data;
}});

export function useOperationalPriceHistory(itemId: string, kind: 'buying' | 'commission', page: number, enabled: boolean) {
  return useQuery<{ total: number; entries: (BuyingPrice | CommissionHistory)[] }>({
    queryKey: ['inventory', 'operational-price-history', itemId, kind, page], enabled,
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase.rpc(kind === 'buying' ? 'get_buying_price_history' : 'get_product_commission_history', { p_item_id: itemId, p_offset: page * 10, p_limit: 10 }).abortSignal(signal);
      if (error) throw error; return data;
    },
  });
}
export function useSetBuyingPrice() {
  const { profile, user } = useAuth(); const qc = useQueryClient();
  const key = `lpg-buying-price:${profile?.tenant_id}:${user?.id}`;
  const [pending, setPending] = useState(() => hasPendingRequest(key));
  const mutation = useMutation({ mutationFn: async (payload: { item_id: string; price_type: PriceType; is_manual: boolean; price?: number; reason: string; expected: string | null } | undefined) => {
    if (!profile || !user) throw new Error('Sign in before saving prices.');
    const request = prepareRequest(key, payload); setPending(true);
    const { error } = await supabase.rpc('set_product_buying_price', { p_payload: request.body, p_request_id: request.id });
    if (!error || isDefiniteRejection(error.code)) { finishRequest(key, request.id); setPending(false); }
    if (error) throw new Error(error.message);
  }, onSuccess: () => qc.invalidateQueries({ queryKey: inventoryKeys.all }) });
  return { ...mutation, hasPending: pending };
}
