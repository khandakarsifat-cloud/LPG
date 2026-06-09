// ── Shared domain types for the Inventory module ─────────────────────────────

export type MovementType =
  | 'purchase'
  | 'sale'
  | 'exchange'
  | 'refill'
  | 'loss'
  | 'adjust_gain'
  | 'adjust_loss';

export type CylinderWeight = '5kg' | '12kg' | '25kg' | '35kg';
export type MouthSize = '20mm' | '22mm';
export type PriceType = 'refill' | 'package';

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
  user_profiles: { full_name: string | null } | null;
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
  sale:         'Sale',
  exchange:     'Exchange',
  refill:       'Refill',
  loss:         'Loss',
  adjust_gain:  'Adjustment (+)',
  adjust_loss:  'Adjustment (−)',
};

export const MOVEMENT_TYPE_COLORS: Record<MovementType, string> = {
  purchase:    '#10b981', // emerald
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
