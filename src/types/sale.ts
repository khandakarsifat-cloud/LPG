import type { CustomerTier } from './inventory.ts';

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
  user_profiles?: { full_name: string | null; email: string | null } | null;
  customers?: {
    name: string;
    phone: string;
    shop_name?: string;
    tier?: string;
    address?: string | null;
  };
  sale_items?: Array<{
    quantity: number;
    unit_price: number;
    line_total: number;
    type: string;
    items?: {
      brand?: string;
      size_kg?: string;
      mouth_size?: string | null;
      lpg_brands?: {
        brand_name: string;
      };
    };
  }>;
}

