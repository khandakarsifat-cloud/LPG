import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { assertBDMobilePhone } from '../lib/bdPhone';

export interface PriceBook {
  tenant_id: string;
  item_id: string;
  customer_tier: string;
  price_type: 'refill' | 'package';
  price: number;
  effective_from: string;
}

export const posKeys = {
  priceBooks: ['price_books'] as const,
};

export const usePriceBooks = () =>
  useQuery<PriceBook[]>({
    queryKey: posKeys.priceBooks,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('price_books')
        .select('*')
        .order('effective_from', { ascending: false });
      if (error) throw error;
      return (data ?? []) as PriceBook[];
    },
  });

export interface POSSalePayload {
  customerId?: string;
  customerPhone: string;           // Required — mandatory customer
  customerName?: string;
  customerShopName?: string;
  customerAddress?: string;
  customerTier?: 'retail' | 'wholesale';
  discountAmount?: number;
  exchangeFee?: number;
  notes?: string;
  items: Array<{
    item_id: string;
    type: 'refill' | 'package' | 'empty_return';
    quantity: number;
    unit_price: number;
  }>;
}

export interface POSSaleResult {
  sale_id: string;
  customer_id: string;
  subtotal: number;
  total_amount: number;
  customer_phone: string;
  customer_name: string;
}

export const useCreatePOSSale = () => {
  const qc = useQueryClient();
  return useMutation<POSSaleResult, Error, POSSalePayload>({
    mutationFn: async (payload) => {
      const customerPhone = assertBDMobilePhone(payload.customerPhone);

      const { data, error } = await supabase.rpc('create_pos_sale', {
        p_customer_phone:      customerPhone,
        p_customer_name:       payload.customerName ?? null,
        p_customer_shop_name:  payload.customerShopName ?? null,
        p_customer_address:    payload.customerAddress ?? null,
        p_customer_tier:       payload.customerTier ?? 'retail',
        p_discount_amount:     payload.discountAmount ?? 0,
        p_exchange_fee:        payload.exchangeFee ?? 0,
        p_notes:               payload.notes ?? null,
        p_items:               payload.items,
        p_customer_id:         payload.customerId ?? null,
      });
      if (error) throw error;
      return data as POSSaleResult;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['inventory'] });
      qc.invalidateQueries({ queryKey: ['customers'] });
      qc.invalidateQueries({ queryKey: ['logistics'] });
      qc.invalidateQueries({ queryKey: ['movements'] });
      qc.invalidateQueries({ queryKey: ['sales'] });
      qc.invalidateQueries({ queryKey: ['dashboard'] });
    },
  });
};
