import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { AdditionalCost, Transit, Truck, CreateTruckPayload, UpdateTruckPayload, TruckStatus, Wallet } from '../types/logistics';

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
  useQuery<Wallet[]>({
    queryKey: logisticsKeys.wallets,
    refetchInterval: 30_000,
    queryFn: async () => {
      const { data, error } = await supabase.from('wallets').select('*').order('created_at').order('wallet_id');
      if (error) throw error;
      return (data ?? []) as Wallet[];
    },
  });

/** Transits for current tenant */
export const useTransits = () =>
  useQuery<Transit[]>({
    queryKey: logisticsKeys.transits,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_transits');
      
      if (error) throw error;
      return (data ?? []) as Transit[];
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
  return useMutation<unknown, Error, { truckId: string; fee: number; clientName: string; destination: string; description: string }>({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.rpc('create_custom_transit', {
        p_payload: { truck_id: payload.truckId, fee: payload.fee, client_name: payload.clientName,
          destination: payload.destination, description: payload.description },
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: logisticsKeys.transits });
      qc.invalidateQueries({ queryKey: logisticsKeys.trucks });
      qc.invalidateQueries({ queryKey: logisticsKeys.wallets });
      qc.invalidateQueries({ queryKey: ['finance'] });
    },
  });
};

/** Update transit costs */
export const useUpdateTransitCosts = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, {
    transitId: string;
    revision: number;
    driverCost: number;
    helperCost: number;
    oilCost: number;
    othersCost: number;
    additionalCosts: AdditionalCost[];
  }>({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.rpc('save_transit_costs', {
        p_transit_id: payload.transitId,
        p_revision: payload.revision,
        p_costs: { driver_cost: payload.driverCost, helper_cost: payload.helperCost, oil_cost: payload.oilCost,
          others_cost: payload.othersCost, additional_costs: payload.additionalCosts },
      });
      if (error) throw error;
      return data;
    },
    onSettled: async () => {
      await Promise.all([qc.invalidateQueries({ queryKey: logisticsKeys.transits }),
        qc.invalidateQueries({ queryKey: ['purchases'] })]);
    },
  });
};

export const useTransitionTransit = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, { transitId: string; revision: number; action: 'complete' | 'cancel' | 'close' }>({
    mutationFn: async ({ transitId, revision, action }) => {
      const { data, error } = await supabase.rpc('transition_transit', { p_transit_id: transitId, p_action: action, p_revision: revision });
      if (error) throw new Error(error.message);
      return data;
    },
    onSettled: async () => {
      await Promise.all([qc.invalidateQueries({ queryKey: logisticsKeys.all }), qc.invalidateQueries({ queryKey: ['purchases'] }), qc.invalidateQueries({ queryKey: ['finance'] })]);
    },
  });
};
