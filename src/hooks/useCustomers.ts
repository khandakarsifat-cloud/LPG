import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { assertBDMobilePhone, getPhoneSearchTerms } from '../lib/bdPhone';

export interface Customer {
  tenant_id: string;
  customer_id: string;
  name: string;
  phone: string;
  shop_name: string | null;
  address: string | null;
  tier: string;
  created_at: string;
}

export type CustomerInput = Omit<Customer, 'customer_id' | 'tenant_id' | 'created_at'>;

export const customerKeys = {
  all: ['customers'] as const,
  list: (search?: string) => ['customers', 'list', search] as const,
};

export const useCustomers = (searchTerm?: string) =>
  useQuery<Customer[]>({
    queryKey: customerKeys.list(searchTerm),
    queryFn: async () => {
      let query = supabase.from('customers').select('*').order('name', { ascending: true });
      if (searchTerm) {
        const escapedSearch = searchTerm.replace(/[%_,]/g, '\\$&');
        const phoneFilters = getPhoneSearchTerms(searchTerm)
          .map((term) => `phone.ilike.%${term.replace(/[%_,]/g, '\\$&')}%`);
        query = query.or([
          `name.ilike.%${escapedSearch}%`,
          `shop_name.ilike.%${escapedSearch}%`,
          ...phoneFilters,
        ].join(','));
      }
      const { data, error } = await query.limit(50);
      if (error) throw error;
      return (data ?? []) as Customer[];
    },
  });

export const useAddCustomer = () => {
  const qc = useQueryClient();
  return useMutation<Customer, Error, CustomerInput>({
    mutationFn: async (payload) => {
      const phone = assertBDMobilePhone(payload.phone);

      // Duplicacy check
      const { data: existing } = await supabase
        .from('customers')
        .select('customer_id')
        .eq('phone', phone)
        .maybeSingle();
      if (existing) {
        throw new Error('A customer with this phone number already exists.');
      }

      // Derive tenant_id from the user profile
      const { data: profile } = await supabase
        .from('user_profiles')
        .select('tenant_id')
        .single();

      if (!profile) throw new Error('No tenant found');

      const { data, error } = await supabase
        .from('customers')
        .insert([{ ...payload, phone, tenant_id: profile.tenant_id }])
        .select()
        .single();
        
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: customerKeys.all });
    },
  });
};
