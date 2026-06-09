import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { LPGBrand, CreateBrandPayload } from '../types/inventory';

export const useLPGBrands = () => {
  return useQuery({
    queryKey: ['lpg_brands'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_lpg_brands', {
        p_active_only: false,
      });

      if (error) throw error;
      return (data as LPGBrand[]) || [];
    },
  });
};

export const useCreateBrand = () => {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (payload: CreateBrandPayload) => {
      const { data, error } = await supabase.rpc('create_lpg_brand', {
        p_brand_name: payload.brand_name,
        p_description: payload.description || null,
      });

      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['lpg_brands'] });
    },
  });
};

export const useUpdateBrand = () => {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (payload: { brand_id: string; brand_name?: string; description?: string; is_active?: boolean }) => {
      const { data, error } = await supabase.rpc('update_lpg_brand', {
        p_brand_id: payload.brand_id,
        p_brand_name: payload.brand_name || null,
        p_description: payload.description || null,
        p_is_active: payload.is_active !== undefined ? payload.is_active : null,
      });

      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['lpg_brands'] });
    },
  });
};
