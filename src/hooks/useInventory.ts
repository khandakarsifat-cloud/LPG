import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Item, InventoryBalance, InventoryMovement, CreateItemPayload, CreateMovementPayload } from '../types/inventory';

// ── Query Keys ────────────────────────────────────────────────────────────────
export const inventoryKeys = {
  all:       ['inventory']                     as const,
  items:     ['inventory', 'items']            as const,
  balances:  ['inventory', 'balances']         as const,
  movements: ['inventory', 'movements']        as const,
  movement:  (id: string) => ['inventory', 'movements', id] as const,
};

// ─────────────────────────────────────────────────────────────────────────────
// QUERIES
// ─────────────────────────────────────────────────────────────────────────────

/** All items for the current tenant */
export const useItems = () =>
  useQuery<Item[]>({
    queryKey: inventoryKeys.items,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('items')
        .select('*')
        .order('brand', { ascending: true });
      if (error) throw error;
      return data ?? [];
    },
  });

/** Inventory balances joined with item details */
export const useInventoryBalances = () =>
  useQuery<InventoryBalance[]>({
    queryKey: inventoryKeys.balances,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('inventory_balances')
        .select('*, items(brand, size_kg, type)')
        .order('last_updated', { ascending: false });
      if (error) throw error;
      return (data ?? []) as InventoryBalance[];
    },
    refetchInterval: 30_000, // poll every 30s for near-real-time feel
  });

/** Recent inventory movements (last 100) */
export const useInventoryMovements = (limit = 100) =>
  useQuery<InventoryMovement[]>({
    queryKey: [...inventoryKeys.movements, limit],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('inventory_movements')
        .select('*, items(brand, size_kg, type), user_profiles(full_name)')
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
    mutationFn: async ({ item_id, movement_type, quantity, notes }) => {
      const { data, error } = await supabase.rpc('create_inventory_movement', {
        p_item_id:       item_id,
        p_movement_type: movement_type,
        p_quantity:      quantity,
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
