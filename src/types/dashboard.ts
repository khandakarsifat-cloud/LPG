import type { StoveType } from './accounting';

export interface DashboardDay { date: string; revenue: number; expense: number | null; collected: number; sales: number }
export interface DashboardSale { sale_id: string; created_at: string; customer: string; items: string | null; amount: number }
export interface DashboardActivity { id: string; kind: 'sale' | 'purchase' | 'payment' | 'financial_entry'; record_id: string; record_kind: string; title: string; description: string; amount: number | null; created_at: string }
export interface DashboardActivityPage { entries: DashboardActivity[]; hasMore: boolean }
export interface DashboardSnapshot {
  date: string; generated_at: string; finance_visible: boolean; days: DashboardDay[];
  sales: DashboardSale[]; bottles: { size_kg: number; quantity: number }[];
  stove_types: (Pick<StoveType, 'type_id' | 'name' | 'system_key'> & { quantity: number })[];
  attention: { customer_due: number | null; customers: number | null; bottles: number | null; bottle_customers: number | null; low_stock: number | null };
  activity: DashboardActivityPage;
}
