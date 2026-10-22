import type { PaymentWallet } from './finance';

export type PurchaseStatus = 'created' | 'in_transit' | 'received' | 'cancelled';
export type PurchasePaymentStatus = 'unpaid' | 'partial' | 'paid';
export type PurchaseType = 'refill' | 'package';

export interface PurchaseItem {
  purchase_item_id: string;
  item_id: string;
  brand_name: string;
  size_kg: number;
  mouth_size: string | null;
  type: PurchaseType;
  quantity: number;
  empty_dispatched: number;
  received_quantity: number | null;
  billed_quantity: number;
  unit_price: number;
  line_total: number;
}

export interface Purchase {
  purchase_id: string;
  truck_id: string | null;
  truck_name: string | null;
  plant_id: string;
  plant_name: string;
  brand_id: string | null;
  company_name: string | null;
  status: PurchaseStatus;
  payment_status: PurchasePaymentStatus;
  subtotal: number;
  commission: number;
  company_payable: number;
  transport_cost: number;
  labour_cost: number;
  total_cost: number;
  notes: string | null;
  receipt_notes: string | null;
  created_at: string;
  dispatched_at: string | null;
  received_at: string | null;
  paid_at: string | null;
  revision: number;
  legacy_record: boolean;
  transport_funded?: number;
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
  component: string;
  amount: number;
  refunded: number;
  remaining: number;
  logistics_amount: number;
  credit_business: boolean;
  sources: { transaction_id: string; wallet_name: string; amount: number; description: string; payment_id?: string }[];
}

export interface PurchaseSettlement {
  total: number; paid: number; due: number; refund_due: number; refunded: number;
  financial_closed_at: string | null; can_cancel: boolean; legacy: boolean; financial_locked: boolean;
  obligations: PurchaseRefundObligation[];
  internal_wallet?: PaymentWallet;
  payment_count: number;
  payments: { transaction_id: string; wallet_name: string; method: string; amount: number; type: string; created_at: string; operation_id: string | null; description: string; reference: string | null; component: string | null; actor: string | null; obligation_id: string | null }[];
}

export interface PurchaseLinePayload {
  purchase_item_id?: string;
  item_id: string;
  type: PurchaseType;
  quantity: number;
  empty_dispatched: number;
  unit_price: number;
}

export interface PurchaseDraft {
  truck_id: string | null;
  transport_cost: number;
  labour_cost: number;
  commission: number;
  notes: string;
  items: PurchaseLinePayload[];
}

export interface CreatePurchasePayload extends PurchaseDraft {
  plant_id: string;
  request_id: string;
}

export interface PurchaseActivity {
  activity_id: string;
  action: string;
  actor_name: string;
  created_at: string;
  details: Record<string, unknown>;
}

export const PURCHASE_STATUS_LABELS: Record<PurchaseStatus, string> = {
  created: 'Created', in_transit: 'In Transit', received: 'Received', cancelled: 'Cancelled',
};
export const PURCHASE_STATUS_COLORS: Record<PurchaseStatus, string> = {
  created: 'var(--text-muted)', in_transit: 'var(--primary)', received: 'var(--accent)', cancelled: 'var(--danger)',
};
export const PURCHASE_STATUS_BG: Record<PurchaseStatus, string> = {
  created: 'var(--surface-subtle)', in_transit: 'var(--primary-weak)', received: 'var(--accent-weak)', cancelled: 'var(--danger-weak)',
};
