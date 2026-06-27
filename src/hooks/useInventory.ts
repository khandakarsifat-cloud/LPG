import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Item, ItemWithBrand, InventoryMovement, CreateItemPayload, CreateMovementPayload } from '../types/inventory';

// ── Query Keys ────────────────────────────────────────────────────────────────
export const inventoryKeys = {
  all:          ['inventory']                              as const,
  items:        ['inventory', 'items']                     as const,
  balances:     ['inventory', 'balances']                  as const,
  movements:    ['inventory', 'movements']                 as const,
  movement:     (id: string) => ['inventory', 'movements', id] as const,
  itemMovements:(id: string) => ['inventory', 'movements', 'item', id] as const,
};

// ─────────────────────────────────────────────────────────────────────────────
// QUERIES
// ─────────────────────────────────────────────────────────────────────────────

/** All items for the current tenant */
export const useItems = () =>
  useQuery<ItemWithBrand[]>({
    queryKey: inventoryKeys.items,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('items')
        .select('*, lpg_brands(brand_id, brand_name)')
        .order('brand', { ascending: true });
      if (error) throw error;
      return (data ?? []) as ItemWithBrand[];
    },
  });

/** Inventory balances — simply fetches all items, as they now contain filled_quantity and empty_quantity */
export const useInventoryBalances = () =>
  useQuery<ItemWithBrand[]>({
    queryKey: inventoryKeys.balances,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('items')
        .select('*, lpg_brands(brand_id, brand_name)')
        .order('brand', { ascending: true });
      if (error) throw error;
      return (data ?? []) as ItemWithBrand[];
    },
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

// ─────────────────────────────────────────────────────────────────────────────
// MUTATIONS
// ─────────────────────────────────────────────────────────────────────────────

/** Create a new product item */
export const useCreateItem = () => {
  const qc = useQueryClient();
  return useMutation<Item, Error, CreateItemPayload>({
    mutationFn: async (payload) => {
      // Derive tenant_id from the user profile
      const { data: profile } = await supabase
        .from('user_profiles')
        .select('tenant_id')
        .single();

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

