import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useBatchedDirectory } from './useBatchedDirectory';
import { supabase } from '../lib/supabase';
import { defaultCustomerFilters } from '../lib/customer';
import { assertBDMobilePhone } from '../lib/bdPhone';
import { customerKeys, type Customer, type CustomerInput } from './useCustomers';
import type { CustomerFilters, CustomerOverview, CustomerProductOptions, CustomerResult, CustomerSummary, CustomerTransaction } from '../types/customer';

export const CUSTOMER_PAGE_SIZE = 12;
export const CUSTOMER_TRANSACTION_PAGE_SIZE = 4;

export function useCustomerDirectory(filters: CustomerFilters, page: number, pageSize = CUSTOMER_PAGE_SIZE) {
  return useBatchedDirectory<CustomerSummary>([...customerKeys.all, 'directory', filters], page, pageSize,
    async (offset, limit, signal) => {
      const { data, error } = await supabase.rpc('get_customer_directory', { p_filters: filters, p_offset: offset, p_limit: limit }).abortSignal(signal);
      if (error) throw error;
      return data as CustomerResult<CustomerSummary>;
    });
}
export function useCustomerOverview() {
  return useQuery<CustomerOverview>({
    queryKey: [...customerKeys.all, 'overview'],
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase.rpc('get_customer_overview').abortSignal(signal);
      if (error) throw error;
      return data as CustomerOverview;
    }, refetchInterval: 30_000,
  });
}
export function useCustomerProfile(id: string, preview?: CustomerSummary) {
  return useQuery<CustomerSummary>({
    queryKey: [...customerKeys.all, 'profile', id],
    placeholderData: preview,
    staleTime: 30_000,
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase.rpc('get_customer_directory', { p_filters: defaultCustomerFilters, p_customer_id: id, p_offset: 0, p_limit: 1 }).abortSignal(signal);
      if (error) throw error;
      const result = data as CustomerResult<CustomerSummary>;
      if (!result.entries[0]) throw new Error('Customer not found.');
      return result.entries[0];
    },
  });
}
export function useCustomerTransactions(id: string, filters: CustomerFilters, page: number, enabled: boolean) {
  return useQuery<CustomerResult<CustomerTransaction>>({
    queryKey: [...customerKeys.all, 'transactions', id, filters, page], enabled,
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase.rpc('get_customer_transactions', { p_customer_id: id, p_filters: filters, p_offset: page * CUSTOMER_TRANSACTION_PAGE_SIZE, p_limit: CUSTOMER_TRANSACTION_PAGE_SIZE }).abortSignal(signal);
      if (error) throw error;
      return data as CustomerResult<CustomerTransaction>;
    },
  });
}
export function useCustomerProductOptions() {
  return useQuery<CustomerProductOptions>({
    queryKey: [...customerKeys.all, 'product-options'],
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase.rpc('get_customer_filter_products').abortSignal(signal);
      if (error) throw error;
      return data as CustomerProductOptions;
    },
  });
}
export function useUpdateCustomer() {
  const qc = useQueryClient();
  return useMutation<Customer, Error, { id: string; payload: CustomerInput }>({
    mutationFn: async ({ id, payload }) => {
      const { data, error } = await supabase.rpc('update_customer_details', { p_customer_id: id, p_payload: { ...payload, phone: assertBDMobilePhone(payload.phone) } });
      if (error) throw new Error(error.message);
      return data as Customer;
    },
    onSuccess: () => {
      for (const key of [customerKeys.all, ['sales'], ['dashboard'], ['inventory', 'movements'], ['pos']]) void qc.invalidateQueries({ queryKey: key });
    },
  });
}
