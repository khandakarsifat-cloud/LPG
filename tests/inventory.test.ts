import test from 'node:test';
import assert from 'node:assert/strict';
import { getSellingPrice } from '../src/lib/productPricing.ts';
import { formatReceipt } from '../src/lib/receipt.ts';

const now = Date.parse('2026-10-18T10:00:00Z');
const row = { item_id: 'a', customer_tier: 'retail', price_type: 'refill' as const, price: 1200, mrp: 1500, effective_from: '2026-01-01' };
test('selling price ignores MRP, expired prices and future prices, with wholesale fallback', () => {
  const rows = [row,
    { ...row, price: 900, effective_from: '2026-10-17', effective_to: '2026-10-18T09:00:00Z' },
    { ...row, price: 2000, effective_from: '2026-11-01' },
    { ...row, item_id: 'b', price: 800 },
  ];
  assert.equal(getSellingPrice(rows, 'a', 'refill', 'retail', now), 1200);
  assert.equal(getSellingPrice(rows, 'a', 'refill', 'wholesale', now), 1200);
  assert.equal(getSellingPrice([...rows, { ...row, customer_tier: 'wholesale', price: 1100 }], 'a', 'refill', 'wholesale', now), 1100);
  assert.equal(getSellingPrice([...rows, { ...row, price: 0, effective_from: '2026-10-18T09:00:00Z' }], 'a', 'refill', 'retail', now), 0);
  assert.equal(getSellingPrice(rows, 'a', 'package', 'retail', now), 0);
});

test('receipts label the saved selling price as Price and keep discounts separate', () => {
  const lines = formatReceipt({ sale_id: 'fixture-sale', created_at: '2026-10-18', shop_name: 'Shop',
    customer_name: 'Customer', customer_phone: '01700000000', customer_tier: 'retail',
    items: [{ name: '12kg', type: 'refill', quantity: 2, unit_price: 1200, line_total: 2400 }],
    subtotal: 2400, discount_amount: 100, exchange_fee: 50, total_amount: 2350 });
  assert(lines.some(line => line.text === 'Price: Tk 1,200.00' && line.right === 'Tk 2,400.00'));
  assert(lines.some(line => line.text === 'Discount' && line.right === '-Tk 100.00'));
  assert(lines.some(line => line.text === 'TOTAL' && line.right === 'Tk 2,350.00'));
  assert(!JSON.stringify(lines).includes('MRP'));
});
