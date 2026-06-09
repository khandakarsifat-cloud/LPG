import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type {
  GasPlant,
  CreateGasPlantPayload,
  UpdateGasPlantPayload,
  CreateAreaOfficerPayload,
  UpdateAreaOfficerPayload,
} from '../types/gasPlants';

const QUERY_KEY = ['gas_plants'] as const;

// ── Queries ───────────────────────────────────────────────────────────────────

export const useGasPlants = (activeOnly = false) => {
  return useQuery({
    queryKey: [...QUERY_KEY, { activeOnly }],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_gas_plants', {
        p_active_only: activeOnly,
      });
      if (error) throw error;
      return (data as GasPlant[]) ?? [];
    },
  });
};

// ── Gas Plant Mutations ───────────────────────────────────────────────────────

export const useCreateGasPlant = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (payload: CreateGasPlantPayload) => {
      const { data, error } = await supabase.rpc('create_gas_plant', {
        p_plant_name: payload.plant_name,
        p_brand_id:   payload.brand_id ?? null,
        p_location:   payload.location ?? null,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: QUERY_KEY }),
  });
};

export const useUpdateGasPlant = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (payload: UpdateGasPlantPayload) => {
      const { data, error } = await supabase.rpc('update_gas_plant', {
        p_plant_id:   payload.plant_id,
        p_plant_name: payload.plant_name ?? null,
        p_brand_id:   payload.brand_id   ?? null,
        p_location:   payload.location   ?? null,
        p_is_active:  payload.is_active  ?? null,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: QUERY_KEY }),
  });
};

// ── Area Officer Mutations ────────────────────────────────────────────────────

export const useCreateAreaOfficer = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (payload: CreateAreaOfficerPayload) => {
      const { data, error } = await supabase.rpc('create_area_officer', {
        p_plant_id:        payload.plant_id,
        p_officer_name:    payload.officer_name,
        p_whatsapp_phone:  payload.whatsapp_phone ?? null,
        p_email:           payload.email          ?? null,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: QUERY_KEY }),
  });
};

export const useUpdateAreaOfficer = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (payload: UpdateAreaOfficerPayload) => {
      const { data, error } = await supabase.rpc('update_area_officer', {
        p_officer_id:      payload.officer_id,
        p_officer_name:    payload.officer_name    ?? null,
        p_whatsapp_phone:  payload.whatsapp_phone  ?? null,
        p_email:           payload.email           ?? null,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: QUERY_KEY }),
  });
};
