import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Truck, CreateTruckPayload, UpdateTruckPayload } from '../types/logistics';

// ── Query Keys ────────────────────────────────────────────────────────────────
export const logisticsKeys = {
  all:    ['logistics']           as const,
  trucks: ['logistics', 'trucks'] as const,
  truck:  (id: string) => ['logistics', 'trucks', id] as const,
};

// ─────────────────────────────────────────────────────────────────────────────
// QUERIES
// ─────────────────────────────────────────────────────────────────────────────

/** All trucks for the current tenant */
export const useTrucks = (activeOnly = true) =>
  useQuery<Truck[]>({
    queryKey: [...logisticsKeys.trucks, activeOnly],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_trucks', {
        p_active_only: activeOnly,
      });
      if (error) throw error;
      return (data ?? []) as Truck[];
    },
  });

// ─────────────────────────────────────────────────────────────────────────────
// MUTATIONS
// ─────────────────────────────────────────────────────────────────────────────

/** Create a new truck */
export const useCreateTruck = () => {
  const qc = useQueryClient();
  return useMutation<Truck, Error, CreateTruckPayload>({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.rpc('create_truck', {
        p_name: payload.name,
        p_serial_no: payload.serial_no,
        p_capacity: payload.capacity,
        p_size: payload.size,
      });
      if (error) throw error;
      return data as Truck;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: logisticsKeys.trucks });
    },
  });
};

/** Update an existing truck */
export const useUpdateTruck = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, { truckId: string } & UpdateTruckPayload>({
    mutationFn: async ({ truckId, ...payload }) => {
      const { data, error } = await supabase.rpc('update_truck', {
        p_truck_id: truckId,
        p_name: payload.name ?? null,
        p_serial_no: payload.serial_no ?? null,
        p_capacity: payload.capacity ?? null,
        p_size: payload.size ?? null,
        p_is_active: payload.is_active ?? null,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: logisticsKeys.trucks });
    },
  });
};

/** Deactivate a truck (soft delete) */
export const useDeactivateTruck = () => {
  const updateTruck = useUpdateTruck();
  return useMutation<unknown, Error, string>({
    mutationFn: async (truckId) => {
      return updateTruck.mutateAsync({
        truckId,
        is_active: false,
      });
    },
  });
};

/** Activate a truck */
export const useActivateTruck = () => {
  const updateTruck = useUpdateTruck();
  return useMutation<unknown, Error, string>({
    mutationFn: async (truckId) => {
      return updateTruck.mutateAsync({
        truckId,
        is_active: true,
      });
    },
  });
};
