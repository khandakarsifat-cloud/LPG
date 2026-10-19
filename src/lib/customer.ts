import type { CustomerFilters } from '../types/customer.ts';

export const defaultCustomerFilters: CustomerFilters = {
  search: '', tier: 'all', sort: 'name_asc', from: '', to: '', item_ids: null,
  transactions_min: '', transactions_max: '', refill_min: '', refill_max: '', package_min: '', package_max: '',
};
export const customerDisplayName = (customer: { name: string; shop_name: string | null; tier: string }) =>
  (customer.tier === 'wholesale' ? customer.shop_name?.trim() : '') || customer.name || 'Unknown';
export const customerDay = (value: string) => new Intl.DateTimeFormat('en-BD', { timeZone: 'Asia/Dhaka', day: 'numeric', month: 'short', year: 'numeric' }).format(new Date(value));
export function customerPeriod(period: string, now = new Date()): { from: string; to: string } {
  const day = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka', year: 'numeric', month: '2-digit', day: '2-digit' }).format(now);
  if (period === 'all') return { from: '', to: '' };
  const date = new Date(`${day}T12:00:00Z`);
  if (period === 'week') date.setUTCDate(date.getUTCDate() - (date.getUTCDay() + 1) % 7);
  else date.setUTCDate(1);
  return { from: date.toISOString().slice(0, 10), to: day };
}
export function customerActivityFilterCount(filters: CustomerFilters) {
  return Number(Boolean(filters.from || filters.to)) + Number(filters.item_ids !== null)
    + (['transactions', 'refill', 'package'] as const).filter(key => filters[`${key}_min`] !== '' || filters[`${key}_max`] !== '').length;
}
