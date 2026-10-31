import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { startOfDay } from 'date-fns';
import type { SaleTransaction } from '../types/sale';
export type { SaleTransaction } from '../types/sale';

export interface DashboardStats {
  todayRevenue: number;
  todayMovements: number;
  totalCustomers: number;
}

export const dashboardKeys = {
  all: ['dashboard'] as const,
  stats: ['dashboard', 'stats'] as const,
};

export const useDashboardStats = () =>
  useQuery<DashboardStats>({
    queryKey: dashboardKeys.stats,
    queryFn: async () => {
      const todayIso = startOfDay(new Date()).toISOString();

      const { data, error } = await supabase.rpc('get_dashboard_stats', { p_since: todayIso });
      if (error) throw error;
      return {
        todayRevenue: Number(data.todayRevenue),
        todayMovements: Number(data.todayMovements),
        totalCustomers: Number(data.totalCustomers),
      };
    },
    refetchInterval: 30_000, // Refresh every 30 seconds
  });

/** Load the exact saved transaction when opened from another module; existing RLS still applies. */
export const useSaleDetails = (saleId: string | null) => useQuery<SaleTransaction>({
  queryKey: ['sales', 'detail', saleId],
  enabled: Boolean(saleId),
  queryFn: async ({ signal }) => {
    if (!saleId) throw new Error('No sale selected');
    const { data, error } = await supabase.from('sales').select(`
      sale_id, sale_tier, status, business_category, created_at, total_amount, additional_charges, paid_amount, subtotal, discount_amount, exchange_fee, notes,
      customers(name, phone, shop_name, address, tier), user_profiles(full_name, email),
      sale_items(item_id, quantity, unit_price, line_total, type, items(item_id, image_url, product_name, brand_id, size_kg, mouth_size, lpg_brands(brand_name)))
    `).eq('sale_id', saleId).abortSignal(signal).single()
      .overrideTypes<SaleTransaction, { merge: false }>();
    if (error) throw error;
    return data;
  },
});

export const useTodaySalesFeed = (page = 0) =>
  useQuery<{ entries: SaleTransaction[]; hasMore: boolean }>({
    queryKey: [...dashboardKeys.all, 'today_sales', page],
    queryFn: async ({ signal }) => {
      const todayIso = startOfDay(new Date()).toISOString();
      const { data, error } = await supabase
        .from('sales')
        .select(`
          sale_id,
          sale_tier,
          created_at,
          total_amount,
          additional_charges,
          paid_amount,
          subtotal,
          discount_amount,
          exchange_fee,
          notes,
          customers (
            name,
            phone,
            shop_name,
            tier
          ),
          sale_items (
            quantity,
            unit_price,
            line_total,
            type,
            items (
              image_url,
              product_name,
              size_kg,
              lpg_brands (
                brand_name
              )
            )
          )
        `)
        .gte('created_at', todayIso)
        .eq('status', 'completed')
        .order('created_at', { ascending: false }).order('sale_id', { ascending: false })
        .range(page * 8, page * 8 + 8).abortSignal(signal);
      
      if (error) throw error;
      const rows = (data as unknown as SaleTransaction[]) || [];
      return { entries: rows.slice(0, 8), hasMore: rows.length > 8 };
    },
    refetchInterval: 30_000,
  });
