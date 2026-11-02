import type { CustomerTier, MouthSize } from './inventory.ts';

export interface SaleTransaction {
  sale_id: string;
  status?: 'completed' | 'voided';
  business_category?: 'lpg' | 'stove';
  sale_tier: CustomerTier;
  created_at: string;
  total_amount: number;
  additional_charges?: number;
  paid_amount?: number;
  subtotal: number;
  discount_amount: number;
  exchange_fee: number;
  notes?: string;
  actor?: { full_name: string | null; email: string | null } | null;
  customers?: {
    name: string;
    phone: string;
    shop_name?: string;
    tier?: string;
    address?: string | null;
  };
  sale_items?: Array<{
    item_id?: string;
    quantity: number;
    unit_price: number;
    line_total: number;
    type: string;
    items?: {
      image_url?: string | null;
      product_name?: string | null;
      item_id?: string;
      brand_id?: string;
      size_kg?: string;
      mouth_size?: MouthSize | null;
      lpg_brands?: {
        brand_name: string;
      };
    };
  }>;
}

