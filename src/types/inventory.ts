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

export type CylinderWeight = '5kg' | '12kg' | '25kg' | '35kg';
export type MouthSize = '20mm' | '22mm';
export type PriceType = 'refill' | 'package';
export type CustomerTier = 'retail' | 'wholesale';

export interface ProductPrice {
  customer_tier: CustomerTier;
  price_type: PriceType;
  price: number;
  mrp: number | null;
  effective_from: string;
}

export interface ProductBuyingCost {
  type: PriceType;
  received_at: string | null;
  bottle_cost: number;
  overhead_per_unit: number;
  commission_per_unit: number;
  estimated_unit_cost: number;
}

export interface ProductWeek {
  start_date: string;
  end_date: string;
  sold_refill: number;
  sold_package: number;
  empty_return: number;
  bought_package: number;
  bought_refill: number;
}

export interface ProductInventory {
  can_manage_prices: boolean;
  commission: { refill_rate: number; package_rate: number; version: string | null };
  prices: ProductPrice[];
  buying_costs: ProductBuyingCost[];
  weeks: ProductWeek[];
}

export interface SetProductCommission {
  itemId: string;
  refillRate: number;
  packageRate: number;
  expected: string | null;
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
  tenant_id: string;
  item_id: string;
  brand_id: string | null;
  brand: string; // Deprecated: use brand_id to reference LPGBrand
  size_kg: number;
  filled_quantity: number;
  empty_quantity: number;
  cylinder_weight: CylinderWeight | null;
  mouth_size: MouthSize | null;
  created_at: string;
  updated_at?: string;
}

export interface ItemWithBrand extends Item {
  lpg_brands: LPGBrand | null;
}

/** Product identity can be shared without granting access to current stock balances. */
export type InventoryProductIdentity = Pick<Item, 'item_id' | 'brand_id' | 'brand' | 'size_kg' | 'mouth_size'> & {
  lpg_brands: Pick<LPGBrand, 'brand_id' | 'brand_name'> | null;
};

export interface InventoryMovement {
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
  items: (Pick<Item, 'brand' | 'size_kg' | 'filled_quantity' | 'empty_quantity' | 'cylinder_weight' | 'mouth_size'> & { lpg_brands: LPGBrand | null }) | null;
  user_profiles: { email: string | null } | null;
}

export interface CreateItemPayload {
  brand_id: string | null;
  brand?: string; // Deprecated: use brand_id
  size_kg: number;
  cylinder_weight?: CylinderWeight | null;
  mouth_size?: MouthSize | null;
}

export interface CreateMovementPayload {
  item_id: string;
  movement_type: MovementType;
  filled_quantity_change: number;
  empty_quantity_change: number;
  notes?: string;
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

export const CYLINDER_WEIGHT_OPTIONS: CylinderWeight[] = ['5kg', '12kg', '25kg', '35kg'];

export const MOUTH_SIZE_OPTIONS: MouthSize[] = ['20mm', '22mm'];

export const CYLINDER_WEIGHT_LABELS: Record<CylinderWeight, string> = {
  '5kg': '5 Kg',
  '12kg': '12 Kg',
  '25kg': '25 Kg',
  '35kg': '35 Kg',
};

export const MOUTH_SIZE_LABELS: Record<MouthSize, string> = {
  '20mm': '20 mm',
  '22mm': '22 mm',
};
