import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { assertBDMobilePhone, getPhoneSearchTerms, normalizePhoneInput } from '../lib/bdPhone';

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

const escapeSupabaseOrValue = (value: string) => value.replace(/[%_,]/g, '\\$&');

const getCustomerSearchTokens = (searchTerm: string) =>
  searchTerm
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean);

const customerMatchesToken = (customer: Customer, token: string) => {
  const phoneTerms = getPhoneSearchTerms(token).map((term) => normalizePhoneInput(term).toLowerCase());
  const searchableText = [
    customer.name,
    customer.shop_name,
    customer.address,
    customer.tier,
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
  const normalizedPhone = normalizePhoneInput(customer.phone).toLowerCase();

  return (
    searchableText.includes(token) ||
    normalizedPhone.includes(normalizePhoneInput(token).toLowerCase()) ||
    phoneTerms.some((term) => normalizedPhone.includes(term))
  );
};

const scoreCustomerMatch = (customer: Customer, tokens: string[]) => {
  const normalizedPhone = normalizePhoneInput(customer.phone).toLowerCase();
  const name = customer.name.toLowerCase();
  const shopName = customer.shop_name?.toLowerCase() ?? '';
  const address = customer.address?.toLowerCase() ?? '';

  return tokens.reduce((score, token) => {
    const normalizedToken = normalizePhoneInput(token).toLowerCase();
    if (normalizedToken && normalizedPhone.startsWith(normalizedToken)) return score + 50;
    if (normalizedToken && normalizedPhone.includes(normalizedToken)) return score + 35;
    if (name.startsWith(token) || shopName.startsWith(token)) return score + 25;
    if (name.includes(token) || shopName.includes(token)) return score + 15;
    if (address.includes(token)) return score + 8;
    return score;
  }, 0);
};

export const useCustomers = (searchTerm?: string) =>
  useQuery<Customer[]>({
    queryKey: customerKeys.list(searchTerm),
    queryFn: async () => {
      const tokens = searchTerm ? getCustomerSearchTokens(searchTerm) : [];
      let query = supabase.from('customers').select('*').order('name', { ascending: true });
      if (tokens.length > 0) {
        const filters = tokens.flatMap((token) => {
          const escapedSearch = escapeSupabaseOrValue(token);
          const phoneFilters = getPhoneSearchTerms(token)
            .map((term) => `phone.ilike.%${escapeSupabaseOrValue(term)}%`);
          return [
            `name.ilike.%${escapedSearch}%`,
            `shop_name.ilike.%${escapedSearch}%`,
            `address.ilike.%${escapedSearch}%`,
            `phone.ilike.%${escapedSearch}%`,
            `tier.ilike.%${escapedSearch}%`,
          ...phoneFilters,
          ];
        });
        query = query.or(filters.join(','));
      }
      const { data, error } = await query.limit(80);
      if (error) throw error;
      const customers = (data ?? []) as Customer[];
      if (tokens.length === 0) return customers;

      return customers
        .filter((customer) => tokens.every((token) => customerMatchesToken(customer, token)))
        .sort((a, b) => scoreCustomerMatch(b, tokens) - scoreCustomerMatch(a, tokens))
        .slice(0, 50);
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
