import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildSaleReceipt, formatReceipt } from '../src/lib/receipt.ts';
import { validateBottles } from '../src/lib/bottles.ts';
import type { SaleBottles } from '../src/types/bottles.ts';

const product = { item_id: 'a', name: 'Brand A 12kg 22mm', size_kg: 12, mouth_size: '22mm', expected: 5, received: 3, difference: 2 };
const sale = { sale_id: 'saved-sale', created_at: '2026-10-26', sale_tier: 'retail' as const,
  customers: { name: 'Current customer', phone: '01700000000' }, subtotal: 500, discount_amount: 20, exchange_fee: 10, total_amount: 490,
  sale_items: [{ item_id: 'a', type: 'empty_return', quantity: 5, unit_price: 0, line_total: 0, items: { brand_id: 'brand-a', lpg_brands: { brand_name: 'Brand A' }, size_kg: '12', mouth_size: '22mm' as const } }] };
const settlement = { unattributed_paid: 0, original_total: 490, additional_charges: 100, total: 590, paid: 540, due: 50, paid_at_checkout: 490, checkout_payments: [], payment_count: 2, payments: [],
  receipt_payments: [{ wallet_name: 'Cash Register', method: 'cash', phase: 'checkout' as const, amount: 490 }, { wallet_name: 'bKash', method: 'bkash', phase: 'collection' as const, amount: 50 }] };
const bottles: SaleBottles = { expected: 5, received: 5, outstanding: 0, obligations: [product], events: [], event_count: 0,
  actual: [{ item_id: 'a', name: product.name, phase: 'checkout', quantity: 1 }, { item_id: 'a', name: product.name, phase: 'collection', quantity: 2 },
    { item_id: 'b', name: 'Brand A 12kg 20mm', phase: 'collection', quantity: 2 }] };

for (const width of [58, 80] as const) test(`${width}mm current receipt combines every collection by actual product and appends unexpected products`, () => {
  const lines = formatReceipt(buildSaleReceipt(sale, settlement, 'Current business', bottles), width);
  assert(lines.some(l => l.text === 'Expected 5 | Received 3'));
  assert(lines.some(l => l.text === 'Expected 0 | Received 2'));
  assert(lines.findIndex(l => l.text === 'Brand A 12kg 20mm') > lines.findIndex(l => l.text === 'Expected 5 | Received 3'));
  assert(lines.some(l => l.text === 'Bottle Settled'));
  assert(lines.some(l => l.text === 'Exchange Cost' && l.right === 'Tk 10.00'));
  assert(lines.some(l => l.text === 'Additional Settlement Cost' && l.right === 'Tk 100.00'));
  assert(lines.some(l => l.text === 'Original invoice total' && l.right === 'Tk 490.00'));
  assert(lines.some(l => l.text === 'TOTAL' && l.right === 'Tk 590.00'));
  assert(lines.some(l => l.text === 'Remaining due' && l.right === 'Tk 50.00'));
});

test('over-receipts remain uncapped, while duplicate original rows cannot double count receipts', () => {
  const duplicateSale = { ...sale, sale_items: [sale.sale_items[0], { ...sale.sale_items[0], quantity: 2 }] };
  const state = { ...bottles, expected: 7, received: 9, actual: [{ ...bottles.actual[0], quantity: 9 }] };
  const lines = formatReceipt(buildSaleReceipt(duplicateSale, settlement, 'Shop', state));
  assert.equal(lines.filter(l => l.text === 'Expected 7 | Received 9').length, 1);
  assert(lines.some(l => l.text === 'Bottle Settled'));
});

test('partial and normalized receipts preserve bottle facts and payment provenance', () => {
  const partial = { ...bottles, received: 1, outstanding: 4, actual: [bottles.actual[0]] };
  const lines = formatReceipt(buildSaleReceipt(sale, settlement, 'Shop', partial));
  assert(lines.some(l => l.text === 'Expected 5 | Received 1'));
  assert(!lines.some(l => l.text === 'Bottle Settled'));
  const historical = formatReceipt(buildSaleReceipt(sale, { ...settlement, paid: 590, due: 0, unattributed_paid: 590, receipt_payments: [] }, 'Shop', { ...bottles, actual: [{ ...bottles.actual[0], quantity: 5 }] }));
  assert(historical.some(l => l.text === 'Expected 5 | Received 5'));
  assert(historical.some(l => l.text === 'Bottle Settled'));
  assert(historical.some(l => l.text === 'Paid without recorded payment methods'));
});

test('acknowledged over-receipts and alternate checkout products are accepted', () => {
  const actual = { item_id: 'b', name: 'Other 5kg 20mm', size_kg: 5, mouth_size: '20mm' };
  assert.equal(validateBottles([product], [product, actual], [{ received_item_id: 'b', quantity: 8, acknowledged: true }], true).error, undefined);
  assert.equal(validateBottles([product], [product, actual], [{ received_item_id: 'b', quantity: 2, acknowledged: true }]).error, undefined);
  assert.match(validateBottles([product], [product, actual], [{ received_item_id: 'b', quantity: 8 }], true).error ?? '', /Acknowledge/);
});
