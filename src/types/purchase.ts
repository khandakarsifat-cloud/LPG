export type PurchaseStatus = 'in_transit' | 'received' | 'cancelled';
export type PurchaseType = 'refill' | 'package';

export interface PurchaseItem {
  purchase_item_id: string;
  item_id: string;
  brand_name: string;
  size_kg: number;
  type: PurchaseType;
  quantity: number;
  unit_price: number;
  line_total: number;
}

export interface Purchase {
  purchase_id: string;
  truck_id: string;
  truck_name: string;
  plant_id: string;
  plant_name: string;
  status: PurchaseStatus;
  transport_cost: number;
  labour_cost: number;
  total_cost: number;
  notes: string | null;
  created_at: string;
  items: PurchaseItem[];
}

export interface CreatePurchaseItemPayload {
  item_id: string;
  type: PurchaseType;
  quantity: number;
  unit_price: number;
}

export interface CreatePurchasePayload {
  truck_id: string;
  plant_id: string;
  transport_cost: number;
  labour_cost: number;
  notes?: string;
  items: CreatePurchaseItemPayload[];
}

export const PURCHASE_STATUS_LABELS: Record<PurchaseStatus, string> = {
  in_transit: 'In Transit',
  received: 'Received',
  cancelled: 'Cancelled',
};

export const PURCHASE_STATUS_COLORS: Record<PurchaseStatus, string> = {
  in_transit: 'var(--primary)',
  received: 'var(--accent)',
  cancelled: 'var(--danger)',
};

export const PURCHASE_STATUS_BG: Record<PurchaseStatus, string> = {
  in_transit: 'rgba(59,130,246,0.12)',
  received: 'rgba(16,185,129,0.12)',
  cancelled: 'rgba(239,68,68,0.12)',
};
