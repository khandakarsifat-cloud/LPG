import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';

export interface BusinessRole { id: string; name: string; active: boolean; system: boolean; assigned: number }
export interface BusinessWeight { size_kg: number; active: boolean; assigned: number }
export function useBusinessCatalogs() {
 const { profile } = useAuth();
 return useQuery<{ roles: BusinessRole[]; weights: BusinessWeight[] }>({ queryKey: ['business-catalogs', profile?.tenant_id], enabled: !!profile,
  queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_business_catalogs').abortSignal(signal); if (error) throw error; return data; } });
}
export function useSaveBusinessCatalog() {
 const cache = useQueryClient();
 return useMutation({ mutationFn: async (input: { kind: 'role' | 'weight'; id: string | null; name: string; active: boolean; remove?: boolean }) => {
  const { error } = await supabase.rpc('save_business_catalog', { p_kind: input.kind, p_id: input.id, p_name: input.name, p_active: input.active, p_remove: !!input.remove });
  if (error) throw new Error(error.message);
 }, onSuccess: () => Promise.all([['business-catalogs'], ['employees'], ['inventory']].map(queryKey => cache.invalidateQueries({ queryKey }))) });
}
export function useSaveBusinessProfile() {
 const cache = useQueryClient();
 return useMutation({ mutationFn: async (name: string) => { const { error } = await supabase.rpc('save_business_profile', { p_name: name }); if (error) throw new Error(error.message); },
  onSuccess: () => cache.invalidateQueries({ queryKey: ['tenant_profile'] }) });
}
