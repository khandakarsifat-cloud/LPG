import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { dhakaToday } from '../lib/businessDate';
import { useAuth } from '../contexts/AuthContext';
import type { DashboardActivityPage, DashboardSnapshot } from '../types/dashboard';
import type { SaleTransaction } from '../types/sale';
export type { SaleTransaction } from '../types/sale';

export const dashboardKeys = { all: ['dashboard'] as const, stats: ['dashboard', 'stats'] as const };
export function useDashboardStats() {
  const { profile } = useAuth();
  return useQuery<DashboardSnapshot>({
    queryKey: [...dashboardKeys.stats, profile?.tenant_id, dhakaToday()], enabled: Boolean(profile),
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase.rpc('get_dashboard_snapshot').abortSignal(signal);
      if (error) throw error; return data;
    }, staleTime: 0, refetchInterval: 30_000,
  });
}
export function useDashboardActivity(page: number) {
  const { profile } = useAuth();
  return useQuery<DashboardActivityPage>({ queryKey: [...dashboardKeys.all, 'activity', profile?.tenant_id, page], enabled: Boolean(profile), staleTime: 0, refetchInterval: 30_000,
    queryFn: async ({ signal }) => { const { data, error } = await supabase.rpc('get_dashboard_activity', { p_offset: page * 20, p_limit: 20 }).abortSignal(signal); if (error) throw error; return data; },
  });
}
/** Load the exact saved transaction; existing RLS still applies. */
export const useSaleDetails = (saleId: string | null) => useQuery<SaleTransaction>({
  queryKey: ['sales', 'detail', saleId], enabled: Boolean(saleId),
  queryFn: async ({ signal }) => {
    if (!saleId) throw new Error('No sale selected');
    const { data, error } = await supabase.from('sales').select(`
      sale_id, sale_tier, status, business_category, created_at, total_amount, additional_charges, paid_amount, subtotal, discount_amount, exchange_fee, notes,
      customers(name, phone, shop_name, address, tier), user_profiles(full_name, email),
      sale_items(item_id, quantity, unit_price, line_total, type, items(item_id, image_url, product_name, brand_id, size_kg, mouth_size, lpg_brands(brand_name)))
    `).eq('sale_id', saleId).abortSignal(signal).single().overrideTypes<SaleTransaction, { merge: false }>();
    if (error) throw error; return data;
  },
});
