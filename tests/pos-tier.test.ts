import test from 'node:test';
import assert from 'node:assert/strict';
import { repriceSaleItems } from '../src/lib/productPricing.ts';
import type { POSSalePayload } from '../src/hooks/usePOS.ts';

const now = Date.parse('2026-10-19T10:00:00Z');
const prices = [
  { item_id: 'a', customer_tier: 'retail', price_type: 'refill' as const, price: 1200, effective_from: '2026-01-01' },
  { item_id: 'a', customer_tier: 'wholesale', price_type: 'refill' as const, price: 1100, effective_from: '2026-01-01' },
  { item_id: 'a', customer_tier: 'retail', price_type: 'package' as const, price: 2500, effective_from: '2026-01-01' },
  { item_id: 'a', customer_tier: 'wholesale', price_type: 'package' as const, price: 2300, effective_from: '2026-01-01' },
];
const cart: POSSalePayload['items'] = [
  { item_id: 'a', type: 'refill', quantity: 2, unit_price: 1200 },
  { item_id: 'a', type: 'package', quantity: 1, unit_price: 2500 },
  { item_id: 'b', type: 'empty_return', quantity: 2, unit_price: 0 },
];

test('switching tiers reprices every existing line in both directions, preserving quantities and original state', () => {
  const wholesale = repriceSaleItems(cart, prices, 'wholesale', now);
  assert.deepEqual(wholesale.map(line => line.unit_price), [1100, 2300, 0]);
  assert.equal(wholesale.reduce((sum, line) => sum + line.unit_price * line.quantity, 0), 4500);
  assert.deepEqual(wholesale.map(line => line.quantity), [2, 1, 2]);
  assert.deepEqual(repriceSaleItems(wholesale, prices, 'retail', now), cart);
  assert.deepEqual(cart.map(line => line.unit_price), [1200, 2500, 0]);
});

test('repricing retains retail fallback, active date windows and zero-priced wholesale entries', () => {
  const rows = [prices[0], prices[2],
    { ...prices[1], price: 9999, effective_from: '2027-01-01' },
    { ...prices[1], price: 999, effective_to: '2026-10-01' },
    { ...prices[3], price: 0 },
  ];
  assert.deepEqual(repriceSaleItems(cart, rows, 'wholesale', now).map(line => line.unit_price), [1200, 0, 0]);
  assert.deepEqual(repriceSaleItems([], rows, 'retail', now), []);
});
