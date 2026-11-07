import { invalidateFreshQueries } from '../lib/invalidateFreshQueries';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { assertBDMobilePhone } from '../lib/bdPhone';
import type { CustomerTier } from '../types/inventory';
import { useState } from 'react';
import { useAuth } from '../contexts/AuthContext';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';
import type { PaymentInput } from '../types/finance';
import type { BottleInput } from '../types/bottles';

export interface PriceBook {
  tenant_id: string;
  item_id: string;
  customer_tier: string;
  price_type: 'refill' | 'package';
  price: number;
  mrp?: number | null;
  effective_from: string;
  effective_to?: string | null;
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
  bottles?: BottleInput;
  payments?: PaymentInput[];
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
  paid_amount: number;
  due: number;
  sale_id: string;
  sale_tier: CustomerTier;
  customer_id: string;
  subtotal: number;
  total_amount: number;
  customer_phone: string;
  customer_name: string;
}

export const useCreatePOSSale = () => {
  const qc = useQueryClient();
  const { profile, user } = useAuth();
  const storageKey = `lpg-pos-pending:${profile?.tenant_id}:${user?.id}`;
  const [hasPending, setHasPending] = useState(() => hasPendingRequest(storageKey));
  const mutation = useMutation<POSSaleResult, Error, POSSalePayload | undefined>({
    mutationFn: async (payload) => {
      if (!profile || !user) throw new Error('Sign in before checkout.');
      const customerPhone = payload ? assertBDMobilePhone(payload.customerPhone) : '';
      const pending = prepareRequest(storageKey, payload ? {
        p_customer_phone:      customerPhone,
        p_customer_name:       payload.customerName ?? null,
        p_customer_shop_name:  payload.customerShopName ?? null,
        p_customer_address:    payload.customerAddress ?? null,
        p_customer_tier:       payload.customerTier ?? 'retail',
        p_discount_amount:     payload.discountAmount ?? 0,
        p_exchange_fee:        payload.exchangeFee ?? 0,
        p_notes:               payload.notes ?? null,
        p_items:               payload.items.filter(line => line.type !== 'empty_return'),
        p_customer_id:         payload.customerId ?? null,
        p_payments:            payload.payments ?? null,
        p_bottles:             payload.bottles ?? (payload.items.some(line => line.type === 'empty_return') ? {
          lines: payload.items.filter(line => line.type === 'empty_return').map(line => ({
            received_item_id: line.item_id, quantity: line.quantity,
          })), note: '',
        } : null),
      } : undefined);
      setHasPending(true);
      const { data, error } = await supabase.rpc('create_pos_sale', { ...pending.body, p_request_id: pending.id });
      if (!error || isDefiniteRejection(error.code)) {
        finishRequest(storageKey, pending.id); setHasPending(false);
      }
      if (error) throw new Error(error.message);
      return data as POSSaleResult;
    },
    onSuccess: () => {
      invalidateFreshQueries(qc, { queryKey: ['inventory'] });
      invalidateFreshQueries(qc, { queryKey: ['customers'] });
      invalidateFreshQueries(qc, { queryKey: ['logistics'] });
      invalidateFreshQueries(qc, { queryKey: ['movements'] });
      invalidateFreshQueries(qc, { queryKey: ['sales'] });
      invalidateFreshQueries(qc, { queryKey: ['dashboard'] });
      invalidateFreshQueries(qc, { queryKey: ['finance'] });
    },
  });
  return { ...mutation, hasPending };
};
