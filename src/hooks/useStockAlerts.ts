import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';

export interface StockAlert { item_id: string; name: string; business_category: string; filled_quantity: number; low_stock_threshold: number }
export function useStockAlerts(low: boolean, search: string, page: number) {
  const { profile } = useAuth();
  return useQuery<{ total: number; entries: StockAlert[] }>({ queryKey: ['inventory', 'stock-alerts', profile?.tenant_id, low, search, page], placeholderData: keepPreviousData, refetchInterval: 30_000,
    queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_stock_alerts', { p_only_low: low, p_search: search, p_offset: page * 20, p_limit: 20 }).abortSignal(signal); if (error) throw error; return data; },
  });
}
export function useSetStockThreshold() {
  const cache = useQueryClient();
  return useMutation({ mutationFn: async ({ item, threshold }: { item: StockAlert; threshold: number }) => {
    const { error } = await supabase.rpc('set_stock_threshold', { p_item_id: item.item_id, p_threshold: threshold, p_expected: item.low_stock_threshold }); if (error) throw new Error(error.message);
  }, onSuccess: () => Promise.all([['inventory'], ['dashboard']].map(queryKey => cache.invalidateQueries({ queryKey }))) });
}
