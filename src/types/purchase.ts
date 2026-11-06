export type PurchaseStatus = 'created' | 'in_transit' | 'received' | 'cancelled';
export type PurchasePaymentStatus = 'unpaid' | 'partial' | 'paid';

export interface PurchaseItem {
  image_url?: string | null;
  purchase_item_id: string;
  item_id: string;
  product_name?: string | null;
  brand_name: string;
  size_kg: number;
  mouth_size: string | null;
  quantity: number;
  empty_dispatched: number;
  unit_price: number;
  bottle_quantity: number;
  bottle_unit_price: number;
  line_total: number;
}

export interface Purchase {
  purchase_id: string;
  business_category?: 'lpg' | 'stove';
  supplier_name?: string;
  vehicle_id: string | null;
  vehicle_name: string | null;
  plant_id: string;
  plant_name: string;
  brand_id: string | null;
  company_name: string | null;
  status: PurchaseStatus;
  payment_status: PurchasePaymentStatus;
  subtotal: number;
  company_payable: number;
  transport_cost: number;
  labour_cost: number;
  total_cost: number;
  payable_amount: number;
  rebate_amount: number;
  notes: string | null;
  receipt_notes: string | null;
  created_at: string;
  dispatched_at: string | null;
  received_at: string | null;
  paid_at: string | null;
  revision: number;
  paid_amount?: number;
  refund_due?: number;
  refunded_amount?: number;
  financial_closed_at?: string | null;
  cancelled_at?: string | null;
  operating_cost?: number;
  items: PurchaseItem[];
}

export interface PurchaseRefundObligation {
  obligation_id: string;
  component: 'purchase';
  amount: number;
  refunded: number;
  remaining: number;
  sources: { transaction_id: string; wallet_name: string; amount: number; description: string; payment_id?: string }[];
}

export interface PurchaseSettlement {
  total: number; rebate_amount: number; rebate_applied: number; company_credit: number; can_rebate: boolean; paid: number; due: number; refund_due: number; refunded: number;
  financial_closed_at: string | null; can_cancel: boolean; financial_locked: boolean;
  obligations: PurchaseRefundObligation[];
  payment_count: number;
  payments: { transaction_id: string; purchase_payment_id?: string | null; wallet_name: string; method: string; amount: number; type: string; created_at: string; operation_id: string | null; description: string; reference: string | null; component: string | null; actor: string | null; obligation_id: string | null }[];
}

export interface PurchaseLinePayload {
  purchase_item_id?: string;
  item_id: string;
  quantity: number;
  unit_price: number;
  bottle_quantity: number;
  bottle_unit_price: number;
}

export interface PurchaseDraft {
  vehicle_id: string | null;
  transport_cost: number;
  labour_cost: number;
  rebate_amount: number;
  notes: string;
  items: PurchaseLinePayload[];
}

export interface CreatePurchasePayload extends PurchaseDraft {
  business_category?: 'lpg' | 'stove';
  supplier_name?: string;
  plant_id: string;
  request_id: string;
}

interface PurchaseActivityEntry {
  activity_id: string;
  actor_name: string;
  created_at: string;
}

export type PurchaseActivity = PurchaseActivityEntry & (
  | { kind: 'activity'; message: string }
  | { kind: 'payment' | 'refund'; amount: number; wallet_entries: Pick<PurchaseSettlement['payments'][number],
    'transaction_id' | 'purchase_payment_id' | 'wallet_name' | 'method' | 'amount' | 'created_at' |
    'operation_id' | 'description' | 'reference'>[] }
);

export const PURCHASE_STATUS_LABELS: Record<PurchaseStatus, string> = {
  created: 'Created', in_transit: 'In Transit', received: 'Received', cancelled: 'Cancelled',
};
export const PURCHASE_STATUS_COLORS: Record<PurchaseStatus, string> = {
  created: 'var(--text-muted)', in_transit: 'var(--primary)', received: 'var(--accent)', cancelled: 'var(--danger)',
};
export const PURCHASE_STATUS_BG: Record<PurchaseStatus, string> = {
  created: 'var(--surface-subtle)', in_transit: 'var(--primary-weak)', received: 'var(--accent-weak)', cancelled: 'var(--danger-weak)',
};
