import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { startOfDay } from 'date-fns';
import type { CustomerTier } from '../types/inventory';

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

export interface SaleTransaction {
  sale_id: string;
  sale_tier: CustomerTier;
  created_at: string;
  total_amount: number;
  subtotal: number;
  discount_amount: number;
  exchange_fee: number;
  notes?: string;
  customer_name?: string;
  customers?: {
    name: string;
    phone: string;
    shop_name?: string;
    tier?: string;
  };
  sale_items?: Array<{
    quantity: number;
    unit_price: number;
    line_total: number;
    type: string;
    items?: {
      brand?: string;
      size_kg?: string;
      lpg_brands?: {
        brand_name: string;
      };
    };
  }>;
}

/** Load the exact saved transaction when opened from another module; existing RLS still applies. */
export const useSaleDetails = (saleId: string | null) => useQuery<SaleTransaction>({
  queryKey: ['sales', 'detail', saleId],
  enabled: Boolean(saleId),
  queryFn: async ({ signal }) => {
    if (!saleId) throw new Error('No sale selected');
    const { data, error } = await supabase.from('sales').select(`
      sale_id, sale_tier, created_at, total_amount, subtotal, discount_amount, exchange_fee, notes,
      customers(name, phone, shop_name, tier),
      sale_items(quantity, unit_price, line_total, type, items(brand, size_kg, lpg_brands(brand_name)))
    `).eq('sale_id', saleId).abortSignal(signal).single()
      .overrideTypes<SaleTransaction, { merge: false }>();
    if (error) throw error;
    return data;
  },
});

export const useTodaySalesFeed = () =>
  useQuery<SaleTransaction[]>({
    queryKey: [...dashboardKeys.all, 'today_sales'],
    queryFn: async () => {
      const todayIso = startOfDay(new Date()).toISOString();
      const { data, error } = await supabase
        .from('sales')
        .select(`
          sale_id,
          sale_tier,
          created_at,
          total_amount,
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
              brand,
              size_kg,
              lpg_brands (
                brand_name
              )
            )
          )
        `)
        .gte('created_at', todayIso)
        .eq('status', 'completed')
        .order('created_at', { ascending: false })
        .limit(50);
      
      if (error) {
        console.error('Error fetching full sales feed:', error);
        // Fallback
        const { data: fallbackData, error: fallbackError } = await supabase
          .from('sales')
          .select('sale_id, sale_tier, created_at, total_amount, subtotal, discount_amount, exchange_fee, notes')
          .gte('created_at', todayIso)
          .eq('status', 'completed')
          .order('created_at', { ascending: false })
          .limit(50);
          
        if (fallbackError) throw fallbackError;
        return (fallbackData as unknown as SaleTransaction[]) || [];
      }
      
      return (data as unknown as SaleTransaction[]) || [];
    },
    refetchInterval: 30_000,
  });
