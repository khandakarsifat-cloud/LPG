// ── Shared domain types for the Inventory module ─────────────────────────────

export type MovementType =
  | 'purchase'
  | 'purchase_adjustment'
  | 'sale'
  | 'exchange'
  | 'refill'
  | 'loss'
  | 'adjust_gain'
  | 'adjust_loss';

export type MouthSize = '20mm' | '22mm';
export type PriceType = 'refill' | 'package';
export type BuyingComponent = 'gas' | 'bottle';
export type CustomerTier = 'retail' | 'wholesale';

export interface ProductPrice {
  customer_tier: CustomerTier;
  price_type: PriceType;
  price: number;
  mrp: number | null;
  effective_from: string;
}

export interface InventoryValuation { internal_transport_value: number; known_value: number; gas_value: number; bottle_value: number; unit_value: number; reconstructed_products: number; lpg_value: number; stove_value: number }

export interface ProductWeek {
  start_date: string;
  end_date: string;
  sold_refill: number;
  sold_package: number;
  bottles_received: number;
  bought_bottles: number;
  bought_gas: number;
}

export interface ProductInventory {
  can_manage_prices: boolean;
  prices: ProductPrice[];
  buying_prices: BuyingPrice[];
  valuation: import('./accounting.ts').CostPool;
  weeks: ProductWeek[];
}

export interface BuyingPrice {
  history_id: string; price_type: BuyingComponent; new_price: number | null; previous_price: number | null;
  automatic_price: number | null; is_manual: boolean; invoice_unit_price: number | null; overhead_per_unit: number | null;
  purchase_id: string | null; source: string; reason: string; effective_at: string;
  actor?: string;
}



export interface SaveProductPrices {
  itemId: string;
  tier: CustomerTier;
  prices: Record<PriceType, { price: number; mrp: number | null }>;
  expected: Record<PriceType, string | null>;
}

export interface LPGBrand {
  tenant_id: string;
  brand_id: string;
  brand_name: string;
  description: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface Item {
  gas_quantity: number;
  bottle_quantity: number;
  unit_quantity: number;
  low_stock_threshold: number;
  image_url?: string | null;
  tenant_id: string;
  item_id: string;
  brand_id: string;
  size_kg: number;
  filled_quantity: number;
  empty_quantity: number;
  mouth_size: MouthSize | null;
  created_at: string;
  updated_at?: string;
}

export interface ItemWithBrand extends Item {
  lpg_brands: LPGBrand | null;
}

/** Product identity can be shared without granting access to current stock balances. */
export type InventoryProductIdentity = Pick<Item, 'item_id' | 'brand_id' | 'size_kg' | 'mouth_size' | 'image_url'> & {
  lpg_brands: Pick<LPGBrand, 'brand_id' | 'brand_name'> | null;
};

export interface InventoryMovement {
  gas_change: number;
  bottle_change: number;
  unit_change: number;
  bottle_transit_change: number;
  tenant_id: string;
  movement_id: string;
  item_id: string;
  movement_type: MovementType;
  filled_quantity_change: number;
  empty_quantity_change: number;
  notes: string | null;
  reference_type: string | null;
  reference_id: string | null;
  created_by: string | null;
  created_at: string;
  items: ({ product_name?: string | null } & Pick<Item, 'size_kg' | 'gas_quantity' | 'bottle_quantity' | 'unit_quantity' | 'mouth_size'> & { lpg_brands: LPGBrand | null }) | null;
  actor: { email: string | null } | null;
}

export interface CreateItemPayload {
  image_url?: string | null;
  brand_id: string;
  size_kg: number;
  mouth_size?: MouthSize | null;
}

export interface CreateBrandPayload {
  brand_name: string;
  description?: string;
}

// Display helpers

export const MOVEMENT_TYPE_LABELS: Record<MovementType, string> = {
  purchase:     'Purchase',
  purchase_adjustment: 'Purchase adjustment',
  sale:         'Sale',
  exchange:     'Exchange',
  refill:       'Refill',
  loss:         'Loss',
  adjust_gain:  'Adjustment (+)',
  adjust_loss:  'Adjustment (−)',
};

export const MOVEMENT_TYPE_COLORS: Record<MovementType, string> = {
  purchase:    '#10b981', // emerald
  purchase_adjustment: '#f59e0b',
  sale:        '#3b82f6', // blue
  exchange:    '#8b5cf6', // violet
  refill:      '#06b6d4', // cyan
  loss:        '#ef4444', // red
  adjust_gain: '#f59e0b', // amber
  adjust_loss: '#f97316', // orange
};


export const MOUTH_SIZE_OPTIONS: MouthSize[] = ['20mm', '22mm'];

export const MOUTH_SIZE_LABELS: Record<MouthSize, string> = {
  '20mm': '20 mm',
  '22mm': '22 mm',
};
