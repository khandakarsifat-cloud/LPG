import { invalidateFreshQueries } from '../lib/invalidateFreshQueries';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import {
  finishRequest,
  hasPendingRequest,
  isDefiniteRejection,
  prepareRequest,
} from '../lib/pendingRequest';
import type {
  OperatingPayment,
  ServiceTrip,
  VehicleAccountingOperation,
  VehicleExpenseCategory,
} from '../types/vehicleAccounting';
export function useVehicleExpenseCategories() {
  return useQuery<VehicleExpenseCategory[]>({
    queryKey: ['logistics', 'expense-categories'],
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase
        .rpc('get_vehicle_expense_categories')
        .abortSignal(signal);
      if (error) throw error;
      return data;
    },
  });
}
export function useSaveVehicleExpenseCategory() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (payload: {
      name: string;
      category_id?: string;
      revision?: number;
      is_active?: boolean;
    }) => {
      const { data, error } = await supabase.rpc(
        'save_vehicle_expense_category',
        { p_payload: payload },
      );
      if (error) throw new Error(error.message);
      return data;
    },
    onSuccess: () =>
      invalidateFreshQueries(qc, { queryKey: ['logistics', 'expense-categories'] }),
  });
}
export function useServiceTrips(
  filters: {
    vehicle_id: string;
    search: string;
    from: string;
    to: string;
    category_id: string;
  },
  page: number,
) {
  return useQuery<{ entries: ServiceTrip[]; total: number }>({
    queryKey: ['logistics', 'service-trips', filters, page],
    refetchInterval: 30_000,
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase
        .rpc('get_service_trip_directory', {
          p_filters: filters,
          p_offset: page * 8,
          p_limit: 8,
        })
        .abortSignal(signal);
      if (error) throw error;
      return data;
    },
  });
}
export function useServiceTrip(id: string | null) {
  return useQuery<ServiceTrip>({
    queryKey: ['logistics', 'service-trip', id],
    enabled: !!id,
    refetchInterval: 30_000,
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase
        .rpc('get_service_trip', { p_service_trip_id: id })
        .abortSignal(signal);
      if (error) throw error;
      return data;
    },
  });
}
export function useOperatingPayments(
  parent: { transit_id?: string; service_trip_id?: string },
  page: number,
) {
  return useQuery<{ entries: OperatingPayment[]; total: number }>({
    queryKey: ['logistics', 'operating-payments', parent, page],
    refetchInterval: 30_000,
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase
        .rpc('get_operating_payments', {
          p_transit_id: parent.transit_id ?? null,
          p_service_trip_id: parent.service_trip_id ?? null,
          p_offset: page * 8,
          p_limit: 8,
        })
        .abortSignal(signal);
      if (error) throw error;
      return data;
    },
  });
}
export function useServiceTripActivity(id: string, page: number) {
  return useQuery<{
    entries: {
      activity_id: string;
      action: string;
      created_at: string;
      details: Record<string, unknown>;
    }[];
    total: number;
  }>({
    queryKey: ['logistics', 'service-activity', id, page],
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase
        .rpc('get_service_trip_activity', {
          p_service_trip_id: id,
          p_offset: page * 8,
          p_limit: 8,
        })
        .abortSignal(signal);
      if (error) throw error;
      return data;
    },
  });
}
export function useVehicleAccountingOperation() {
  const { profile, user } = useAuth();
  const qc = useQueryClient();
  const key = `lpg-vehicle-accounting:${profile?.tenant_id}:${user?.id}`;
  const mutation = useMutation({
    mutationFn: async (op?: VehicleAccountingOperation) => {
      if (!profile || !user)
        throw new Error('Sign in before recording vehicle costs.');
      const request = prepareRequest(key, op);
      const body = request.body;
      const result =
        body.action === 'save'
          ? await supabase.rpc('save_service_trip', {
              p_payload: body.payload,
              p_request_id: request.id,
            })
          : body.action === 'payment'
            ? await supabase.rpc('record_operating_payment', {
                p_payload: body.payload,
                p_request_id: request.id,
              })
            : await supabase.rpc('finalize_service_trip', {
                p_service_trip_id: body.service_trip_id,
                p_revision: body.revision,
                p_request_id: request.id,
              });
      if (!result.error || isDefiniteRejection(result.error.code))
        finishRequest(key, request.id);
      if (result.error) throw new Error(result.error.message);
      return result.data as { service_trip_id?: string };
    },
    onSuccess: () =>
      Promise.all(
        [['logistics'], ['finance'], ['employees'], ['purchases']].map(
          (queryKey) => invalidateFreshQueries(qc, { queryKey }),
        ),
      ),
  });
  return { ...mutation, hasPending: hasPendingRequest(key) };
}
