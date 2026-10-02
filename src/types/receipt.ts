export interface ReceiptItem {
  name: string;
  type: 'refill' | 'package' | 'empty_return';
  quantity: number;
  unit_price: number;
  line_total: number;
}

export interface ReceiptData {
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
