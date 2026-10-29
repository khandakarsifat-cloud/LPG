export interface BottleProduct { item_id: string; name: string; size_kg: number; mouth_size: string | null }
export interface BottleObligation extends BottleProduct { expected: number; received: number; difference: number }
export interface BottleReceiptLine { received_item_id: string; quantity: number; acknowledged?: boolean }
export interface BottleInput { lines: BottleReceiptLine[]; note: string }
export interface BottleCollection extends BottleInput { fee: number }
export interface BottleEvent {
 id: string; created_at: string; kind: 'bottles' | 'payment' | 'sale'; phase: 'checkout' | 'collection'; note: string; amount: number; actor: string;
 expense: number; expense_wallet_name: string | null;
 lines: Array<BottleReceiptLine & { received_name: string }>;
}
export interface SaleBottles {
 expected: number; received: number; outstanding: number; obligations: BottleObligation[];
 actual: Array<{ phase: 'checkout' | 'collection'; item_id: string; name: string; quantity: number }>;
 event_count: number; events: BottleEvent[];
}
export interface SalesFilters { search: string; payment: string; bottles: string; from: string; to: string; sort: string; tier: string }
export interface SaleSummary {
 sale_id: string; customer_id: string; created_at: string; sale_tier: 'retail' | 'wholesale'; name: string; phone: string; shop_name: string | null;
 original_total: number; additional_charges: number; total_amount: number; paid_amount: number; due: number;
 expected: number; outstanding_bottles: number; received_bottles: number;
 items: Array<{ item_id: string; name: string; type: string; quantity: number }>;
}
