import test from 'node:test';
import assert from 'node:assert/strict';
import { getSellingPrice } from '../src/lib/productPricing.ts';
import { formatReceipt } from '../src/lib/receipt.ts';
import { groupInventoryByBrand } from '../src/lib/inventoryGroups.ts';
import { inventoryHistoryBounds, inventoryMovementActions, inventoryMovementSource } from '../src/lib/inventoryMovement.ts';
import type { ItemWithBrand, LPGBrand } from '../src/types/inventory.ts';

const now = Date.parse('2026-10-18T10:00:00Z');

test('inventory history calendar includes the complete Bangladesh day and supports open bounds', () => {
  assert.deepEqual(inventoryHistoryBounds('2026-10-01', '2026-10-01'), { since: '2026-09-30T18:00:00.000Z', until: '2026-10-01T18:00:00.000Z' });
  assert.deepEqual(inventoryHistoryBounds('', '2028-02-29'), { since: undefined, until: '2028-02-29T18:00:00.000Z' });
  assert.deepEqual(inventoryHistoryBounds('2026-12-31', ''), { since: '2026-12-30T18:00:00.000Z', until: undefined });
  assert.deepEqual(inventoryHistoryBounds('', ''), { since: undefined, until: undefined });
});
const row = { item_id: 'a', customer_tier: 'retail', price_type: 'refill' as const, price: 1200, mrp: 1500, effective_from: '2026-01-01' };

test('inventory history links recorded references and exact legacy notes, never guessing a sale from short notes', () => {
  const id = 'a1000000-0000-4000-8000-000000000001';
  const movement = { movement_type: 'purchase' as const, reference_type: null, reference_id: null, notes: `Received goods from Purchase ${id}` };
  assert.deepEqual(inventoryMovementSource(movement), { kind: 'purchase', id });
  assert.deepEqual(inventoryMovementSource({ ...movement, notes: `Empty bottles sent for refill (Purchase ${id})` }), { kind: 'purchase', id });
  assert.deepEqual(inventoryMovementSource({ ...movement, notes: `Quantity adjustment for Purchase ${id}` }), { kind: 'purchase', id });
  assert.deepEqual(inventoryMovementSource({ ...movement, movement_type: 'sale', notes: 'POS Sale #a1000000' }), { kind: 'sale', id: null });
  assert.deepEqual(inventoryMovementSource({ ...movement, movement_type: 'sale', reference_type: 'sale', reference_id: id }), { kind: 'sale', id });
  assert.deepEqual(inventoryMovementSource({ ...movement, movement_type: 'adjust_gain', notes: `Counted ${id}` }), { kind: null, id: null });
});

test('inventory history describes separate effects, counterparties and cancellations from recorded deltas', () => {
  const movement = { movement_type: 'sale' as const, reference_type: 'sale', filled_quantity_change: -2, empty_quantity_change: 2 };
  assert.deepEqual(inventoryMovementActions(movement, 'sale', 'Rahim'), ['Sold to Rahim on POS sale', 'Received empty from Rahim on POS sale']);
  assert.deepEqual(inventoryMovementActions({ ...movement, filled_quantity_change: 0, empty_quantity_change: -5, reference_type: 'purchase_dispatch' }, 'purchase', 'Jamuna Gas'), ['Sent empty to Jamuna Gas (plant) on purchase']);
  assert.deepEqual(inventoryMovementActions({ ...movement, filled_quantity_change: 5, empty_quantity_change: 0, reference_type: 'purchase_receipt_new' }, 'purchase', 'Jamuna Gas'), ['Received package from Jamuna Gas (plant) on purchase']);
  assert.deepEqual(inventoryMovementActions({ ...movement, reference_type: 'purchase_cancellation' }, 'purchase', 'Jamuna Gas'), ['Reversed received stock from Jamuna Gas (plant) on cancelled purchase', 'Restored empty from Jamuna Gas (plant) on cancelled purchase']);
});
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

test('inventory uses configured brand order, ascending weights and stable mouth-size ties without mutating input', () => {
  const brand = (id: string, name: string, active = true): LPGBrand => ({ tenant_id: 'tenant', brand_id: id, brand_name: name,
    description: null, is_active: active, created_at: '', updated_at: '' });
  const a = brand('a', 'Alpha');
  const b = brand('b', 'Beta', false);
  const item = (id: string, company: LPGBrand | null, weight: number, mouth: '20mm' | '22mm' = '22mm'): ItemWithBrand => ({
    tenant_id: 'tenant', item_id: id, brand_id: company?.brand_id ?? null, brand: company?.brand_name ?? 'Legacy', size_kg: weight,
    filled_quantity: 0, empty_quantity: 0, cylinder_weight: null, mouth_size: mouth, created_at: '', lpg_brands: company,
  });
  const items = [item('large', a, 25), item('beta', b, 12), item('wide', a, 12), item('small', a, 5), item('narrow', a, 12, '20mm'), item('legacy', null, 35)];
  const before = [...items];
  const groups = groupInventoryByBrand(items, [b, a]);
  assert.deepEqual(groups.map(group => group.name), ['Beta', 'Alpha', 'Legacy']);
  assert.deepEqual(groups[1].items.map(product => product.item_id), ['small', 'narrow', 'wide', 'large']);
  assert.deepEqual(items, before);
  assert.equal(groups[0].items.length, 1, 'inactive brands with stock remain visible');
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
