import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Truck, CreateTruckPayload, UpdateTruckPayload, TruckStatus } from '../types/logistics';

// ── Query Keys ────────────────────────────────────────────────────────────────
export const logisticsKeys = {
  all:      ['logistics']           as const,
  trucks:   ['logistics', 'trucks'] as const,
  truck:    (id: string) => ['logistics', 'trucks', id] as const,
  wallets:  ['logistics', 'wallets'] as const,
  transits: ['logistics', 'transits'] as const,
};

// ─────────────────────────────────────────────────────────────────────────────
// QUERIES
// ─────────────────────────────────────────────────────────────────────────────

/** All trucks for the current tenant */
export const useTrucks = () =>
  useQuery<Truck[]>({
    queryKey: logisticsKeys.trucks,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_trucks', {
        p_active_only: false,
      });
      if (error) throw error;
      return (data ?? []) as Truck[];
    },
  });

/** Wallets for current tenant */
export const useWallets = () =>
  useQuery({
    queryKey: logisticsKeys.wallets,
    queryFn: async () => {
      const { data, error } = await supabase.from('wallets').select('*');
      if (error) throw error;
      return data;
    },
  });

/** Transits for current tenant */
export const useTransits = () =>
  useQuery({
    queryKey: logisticsKeys.transits,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('transits')
        .select(`
          *,
          trucks!inner ( name )
        `)
        .order('created_at', { ascending: false });
      
      if (error) throw error;
      return data.map((t: any) => ({
        ...t,
        truck_name: t.trucks?.name
      }));
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
        p_name:      payload.name,
        p_serial_no: payload.serial_no,
        p_capacity:  payload.capacity,
        p_size:      payload.size,
        p_location:  payload.location ?? null,
      });
      if (error) throw error;
      return data as Truck;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: logisticsKeys.trucks });
    },
  });
};

/** Update an existing truck (name, serial, capacity, size, location) */
export const useUpdateTruck = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, { truckId: string } & UpdateTruckPayload>({
    mutationFn: async ({ truckId, ...payload }) => {
      const { data, error } = await supabase.rpc('update_truck', {
        p_truck_id:  truckId,
        p_name:      payload.name ?? null,
        p_serial_no: payload.serial_no ?? null,
        p_capacity:  payload.capacity ?? null,
        p_size:      payload.size ?? null,
        p_status:    payload.status ?? null,
        p_location:  payload.location ?? null,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: logisticsKeys.trucks });
    },
  });
};

/** Quickly set a truck's operational status */
export const useSetTruckStatus = () => {
  const updateTruck = useUpdateTruck();
  return useMutation<unknown, Error, { truckId: string; status: TruckStatus }>({
    mutationFn: ({ truckId, status }) =>
      updateTruck.mutateAsync({ truckId, status }),
  });
};

/** Set / clear a truck's current location */
export const useSetTruckLocation = () => {
  const updateTruck = useUpdateTruck();
  return useMutation<unknown, Error, { truckId: string; location: string | null }>({
    mutationFn: ({ truckId, location }) =>
      updateTruck.mutateAsync({ truckId, location }),
  });
};

/** Create custom transit */
export const useCreateCustomTransit = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, { truckId: string; fee: number; notes: string }>({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.rpc('create_custom_transit', {
        p_truck_id: payload.truckId,
        p_fee: payload.fee,
        p_notes: payload.notes,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: logisticsKeys.transits });
      qc.invalidateQueries({ queryKey: logisticsKeys.trucks });
    },
  });
};

/** Update transit costs */
export const useUpdateTransitCosts = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, {
    transitId: string;
    driverCost: number;
    helperCost: number;
    oilCost: number;
    additionalCosts: any[];
    status: string;
  }>({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.rpc('update_transit_costs', {
        p_transit_id: payload.transitId,
        p_driver_cost: payload.driverCost,
        p_helper_cost: payload.helperCost,
        p_oil_cost: payload.oilCost,
        p_additional_costs: payload.additionalCosts,
        p_status: payload.status,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: logisticsKeys.transits });
      qc.invalidateQueries({ queryKey: logisticsKeys.wallets });
      qc.invalidateQueries({ queryKey: logisticsKeys.trucks });
    },
  });
};
