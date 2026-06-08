// ── Shared domain types for the Inventory module ─────────────────────────────

export type ItemType = 'gas_only' | 'cylinder_only' | 'package';

export type MovementType =
  | 'purchase'
  | 'sale'
  | 'exchange'
  | 'refill'
  | 'loss'
  | 'adjust_gain'
  | 'adjust_loss';

export interface Item {
  tenant_id: string;
  item_id: string;
  brand: string;
  size_kg: number;
  type: ItemType;
  created_at: string;
}

export interface InventoryBalance {
  tenant_id: string;
  item_id: string;
  current_quantity: number;
  last_updated: string;
  items: Item | null;
}

export interface InventoryMovement {
  tenant_id: string;
  movement_id: string;
  item_id: string;
  movement_type: MovementType;
  quantity_change: number;
  notes: string | null;
  reference_type: string | null;
  reference_id: string | null;
  created_by: string | null;
  created_at: string;
  items: Pick<Item, 'brand' | 'size_kg' | 'type'> | null;
  user_profiles: { full_name: string | null } | null;
}

export interface CreateItemPayload {
  brand: string;
  size_kg: number;
  type: ItemType;
}

export interface CreateMovementPayload {
  item_id: string;
  movement_type: MovementType;
  quantity: number;
  notes?: string;
}

// Display helpers
export const ITEM_TYPE_LABELS: Record<ItemType, string> = {
  gas_only:      'Gas Only',
  cylinder_only: 'Cylinder Asset',
  package:       'Full Package',
};

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
