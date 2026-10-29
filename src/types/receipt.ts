export interface ReceiptItem {
  item_id?: string;
  name: string;
  type: 'refill' | 'package' | 'empty_return';
  quantity: number;
  unit_price: number;
  line_total: number;
}

export interface ReceiptData {
  additional_charges?: number;
  bottles?: { expected: number; received: number; outstanding: number;
    actual: Array<{ phase: 'checkout' | 'collection'; item_id?: string; name: string; quantity: number }>;
    obligations: Array<{ name: string; expected: number }> };
  payments: Array<{ wallet_name: string; method: string; amount: number; phase?: 'checkout' | 'collection' }>;
  paid_amount: number;
  due_amount: number;
  unattributed_paid: number;
  sale_id: string;
  created_at: string;
  shop_name?: string;
  customer_name: string;
  customer_phone: string;
  customer_tier: string;
  items: ReceiptItem[];
  subtotal: number;
  discount_amount: number;
  exchange_fee: number;
  total_amount: number;
  notes?: string;
}
