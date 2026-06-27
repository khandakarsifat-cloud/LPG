import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { startOfDay } from 'date-fns';

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

      // 1. Today's Revenue (sum of total_amount from sales completed today)
      const { data: salesData, error: salesError } = await supabase
        .from('sales')
        .select('total_amount')
        .gte('created_at', todayIso)
        .eq('status', 'completed');
        
      if (salesError) throw salesError;
      
      const todayRevenue = salesData.reduce((acc, curr) => acc + Number(curr.total_amount || 0), 0);

      // 2. Today's Movements Count
      const { count: movementsCount, error: movementsError } = await supabase
        .from('inventory_movements')
        .select('*', { count: 'exact', head: true })
        .gte('created_at', todayIso);

      if (movementsError) throw movementsError;

      // 3. Total Active Customers
      const { count: customersCount, error: customersError } = await supabase
        .from('customers')
        .select('*', { count: 'exact', head: true });

      if (customersError) throw customersError;

      return {
        todayRevenue,
        todayMovements: movementsCount || 0,
        totalCustomers: customersCount || 0,
      };
    },
    refetchInterval: 30_000, // Refresh every 30 seconds
  });

export interface SaleTransaction {
  sale_id: string;
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

export const useTodaySalesFeed = () =>
  useQuery<SaleTransaction[]>({
    queryKey: [...dashboardKeys.all, 'today_sales'],
    queryFn: async () => {
      const todayIso = startOfDay(new Date()).toISOString();
      const { data, error } = await supabase
        .from('sales')
        .select(`
          sale_id,
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
          .select('sale_id, created_at, total_amount, subtotal, discount_amount, exchange_fee, notes')
          .gte('created_at', todayIso)
          .eq('status', 'completed')
          .order('created_at', { ascending: false })
          .limit(50);
          
        if (fallbackError) throw fallbackError;
        return (fallbackData as any) || [];
      }
      
      return (data as any) || [];
    },
    refetchInterval: 30_000,
  });
