import type { Customer } from '../hooks/useCustomers';
import type { InventoryProductIdentity, LPGBrand } from './inventory';

export type CustomerSortBy = 'sold' | 'due' | 'name' | 'last_sale';
export type CustomerSort = `${CustomerSortBy}_${'asc' | 'desc'}`;
export interface CustomerFilters {
  search: string; tier: 'all' | 'retail' | 'wholesale'; sort: CustomerSort;
  from: string; to: string; item_ids: string[] | null;
  transactions_min: string; transactions_max: string;
  refill_min: string; refill_max: string; package_min: string; package_max: string;
}
export interface CustomerSummary extends Customer {
  display_name: string; transactions: number; refill: number; package: number; total_sold: number;
  total_sold_amount: number; total_due: number; last_transaction_at: string | null;
}
export interface CustomerOverview {
  wholesale: number; retail: number; new_wholesale: number; new_retail: number;
  inactive_wholesale: number; inactive_retail: number; week_start: string; inactive_since: string;
}
export interface CustomerTransaction {
  sale_id: string; created_at: string; sale_tier: 'retail' | 'wholesale'; total_amount: number;
  refill: number; package: number; products: string;
}
export interface CustomerProductOptions { items: InventoryProductIdentity[]; brands: Pick<LPGBrand, 'brand_id' | 'brand_name'>[] }
export interface CustomerResult<T> { entries: T[]; total: number }
