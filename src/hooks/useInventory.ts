import { readAllRows } from '../lib/queryPages';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';
import type { Item, ItemWithBrand, InventoryMovement, CreateItemPayload, CreateMovementPayload } from '../types/inventory';
import type { ProductInventory, SaveProductPrices, SetProductCommission } from '../types/inventory';
import { posKeys } from './usePOS';
import { inventoryMovementSource, PURCHASE_MOVEMENT_FILTER, SALE_MOVEMENT_FILTER, type InventoryHistorySource } from '../lib/inventoryMovement';

// ── Query Keys ────────────────────────────────────────────────────────────────
export const inventoryKeys = {
  all:          ['inventory']                              as const,
  items:        ['inventory', 'items']                     as const,
  balances:     ['inventory', 'balances']                  as const,
  movements:    ['inventory', 'movements']                 as const,
  movement:     (id: string) => ['inventory', 'movements', id] as const,
  itemMovements:(id: string) => ['inventory', 'movements', 'item', id] as const,
  product: (id: string) => ['inventory', 'product', id] as const,
};

// ─────────────────────────────────────────────────────────────────────────────
// QUERIES
// ─────────────────────────────────────────────────────────────────────────────

/** All items for the current tenant */
export const useItems = () =>
  useQuery<ItemWithBrand[]>({
    queryKey: inventoryKeys.items,
    queryFn: async ({ signal }) => readAllRows<ItemWithBrand>((from, to) => supabase
      .from('items').select('*, lpg_brands(brand_id, brand_name)')
      .order('brand', { ascending: true }).order('item_id', { ascending: true })
      .range(from, to).abortSignal(signal).overrideTypes<ItemWithBrand[], { merge: false }>()),
  });

/** Inventory balances — simply fetches all items, as they now contain filled_quantity and empty_quantity */
export const useInventoryBalances = () =>
  useQuery<ItemWithBrand[]>({
    queryKey: inventoryKeys.balances,
    queryFn: async ({ signal }) => readAllRows<ItemWithBrand>((from, to) => supabase
      .from('items').select('*, lpg_brands(brand_id, brand_name)')
      .order('brand', { ascending: true }).order('item_id', { ascending: true })
      .range(from, to).abortSignal(signal).overrideTypes<ItemWithBrand[], { merge: false }>()),
    refetchInterval: 30_000,
  });

/** Recent inventory movements (last 100) */
export const useInventoryMovements = (limit = 100) =>
  useQuery<InventoryMovement[]>({
    queryKey: [...inventoryKeys.movements, limit],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('inventory_movements')
        .select('*, items(brand, size_kg, filled_quantity, empty_quantity, cylinder_weight, mouth_size, lpg_brands(brand_id, brand_name)), user_profiles(email)')
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return (data ?? []) as InventoryMovement[];
    },
    refetchInterval: 15_000,
  });

export const INVENTORY_HISTORY_PAGE_SIZE = 10;
export const useInventoryHistory = ({ source, itemIds, page }: {
  source: InventoryHistorySource; itemIds: string[] | null; page: number;
}) => {
  const { can } = useAuth();
  const canReadSales = can('sales:view') || can('receipts:print') || can('dashboard:view');
  return useQuery({
    queryKey: [...inventoryKeys.movements, 'history', source, itemIds ? [...itemIds].sort() : null, page, canReadSales],
    queryFn: async ({ signal }) => {
      if (itemIds?.length === 0) return { entries: [], hasMore: false };
      let query = supabase.from('inventory_movements')
        .select('*, items(brand, size_kg, filled_quantity, empty_quantity, cylinder_weight, mouth_size, lpg_brands(brand_id, brand_name)), user_profiles(email)')
        .order('created_at', { ascending: false }).order('movement_id', { ascending: false });
      if (source === 'sale') query = query.or(SALE_MOVEMENT_FILTER);
      if (source === 'purchase') query = query.or(PURCHASE_MOVEMENT_FILTER);
      if (itemIds) query = query.in('item_id', itemIds);
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
      qc.invalidateQueries({ queryKey: inventoryKeys.items });
      qc.invalidateQueries({ queryKey: inventoryKeys.balances });
    },
  });
};

/** Create an inventory movement via the secure server-side RPC */
export const useCreateMovement = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, CreateMovementPayload>({
    mutationFn: async ({ item_id, movement_type, filled_quantity_change, empty_quantity_change, notes }) => {
      const { data, error } = await supabase.rpc('create_inventory_movement', {
        p_item_id:       item_id,
        p_movement_type: movement_type,
        p_filled_quantity_change: filled_quantity_change,
        p_empty_quantity_change: empty_quantity_change,
        p_notes:         notes ?? null,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: inventoryKeys.balances });
      qc.invalidateQueries({ queryKey: inventoryKeys.movements });
    },
  });
};

/** All movements for a single item — used by the per-product history modal */
export const useItemMovements = (itemId: string) =>
  useQuery<InventoryMovement[]>({
    queryKey: inventoryKeys.itemMovements(itemId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('inventory_movements')
        .select('*, items(brand, size_kg, filled_quantity, empty_quantity, cylinder_weight, mouth_size, lpg_brands(brand_id, brand_name)), user_profiles(email)')
        .eq('item_id', itemId)
        .order('created_at', { ascending: false });
      if (error) throw error;
      return (data ?? []) as InventoryMovement[];
    },
    enabled: !!itemId,
    refetchInterval: 15_000,
  });

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
    onSuccess: async () => { await qc.invalidateQueries({ queryKey: inventoryKeys.all }); },
  });
};
