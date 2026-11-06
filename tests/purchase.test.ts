import { test } from 'node:test';
import assert from 'node:assert/strict';
import { emptyPurchaseDraft, purchaseAccess, purchaseDraft, purchaseTotals, purchaseEmptyShortages, validatePurchaseDraft } from '../src/lib/purchase.ts';
import { inventoryMovementLabel } from '../src/lib/inventoryMovement.ts';
import type { Purchase } from '../src/types/purchase.ts';

const purchase: Purchase = {
  purchase_id: 'purchase', plant_id: 'plant', plant_name: 'Plant', brand_id: 'brand', company_name: 'Company',
  vehicle_id: 'vehicle', vehicle_name: 'Vehicle', status: 'created', payment_status: 'unpaid',
  subtotal: 128000, company_payable: 128000, transport_cost: 2600, labour_cost: 1300, total_cost: 131900,
  payable_amount: 129300, rebate_amount: 0, notes: '', receipt_notes: null, created_at: '2026-11-03T00:00:00Z',
  dispatched_at: null, received_at: null, paid_at: null, revision: 1,
  items: [{ purchase_item_id: 'components', item_id: 'item', brand_name: 'Company', size_kg: 12, mouth_size: '22mm',
    quantity: 100, bottle_quantity: 30, empty_dispatched: 0, unit_price: 800, bottle_unit_price: 1600, line_total: 128000 }],
};

test('a manual rebate validates independently of gross component and landed costs', () => {
  const draft = { ...purchaseDraft(purchase), rebate_amount: 5000 };
  assert.equal(validatePurchaseDraft(draft), null);
  assert.deepEqual(purchaseTotals(draft.items, draft.transport_cost, draft.labour_cost), { subtotal: 128000, company_payable: 128000, total_cost: 131900 });
  assert.match(validatePurchaseDraft({ ...draft, rebate_amount: 128000.01 }) ?? '', /cannot exceed/);
  assert.match(validatePurchaseDraft({ ...draft, rebate_amount: 1.234 }) ?? '', /two decimals/);
});

test('rebate corrections before completion preserve locked stock costs', () => {
  const settled = { ...purchase, status: 'in_transit' as const, payment_status: 'paid' as const, paid_amount: 124300, rebate_amount: 5000 };
  assert.equal(purchaseAccess(settled).pay, false);
  const corrected = { ...settled, payment_status: 'partial' as const, rebate_amount: 4000 };
  const access = purchaseAccess(corrected, true, true, true);
  assert.equal(access.pay, true);
  assert.equal(access.financials, false);
  assert.equal(access.products, false);
});

test('100 Gas and 30 Bottles require 70 empties and one received physical quantity', () => {
  const draft = purchaseDraft(purchase);
  assert.equal(validatePurchaseDraft(draft), null);
  assert.deepEqual(purchaseTotals(draft.items, 2600, 1300), { subtotal: 128000, company_payable: 128000, total_cost: 131900 });
  const stock = [{ item_id: 'item', empty_quantity: 60, lpg_brands: { brand_name: 'Company' }, size_kg: 12 }];
  assert.deepEqual(purchaseEmptyShortages(draft.items, stock).map(s => [s.required, s.available, s.missing]), [[70, 60, 10]]);
});

test('Bottle-only purchases, excess Bottles and duplicate product lines are rejected', () => {
  const draft = purchaseDraft(purchase); const line = draft.items[0];
  assert.match(validatePurchaseDraft({ ...draft, items: [{ ...line, quantity: 0, bottle_quantity: 1 }] }) ?? '', /Gas quantity/);
  assert.match(validatePurchaseDraft({ ...draft, items: [{ ...line, bottle_quantity: 101 }] }) ?? '', /Bottle quantity/);
  assert.match(validatePurchaseDraft({ ...draft, items: [line, line] }) ?? '', /one purchase line/);
  assert.equal(validatePurchaseDraft({ ...draft, items: [{ ...line, bottle_quantity: 100 }] }), null);
  assert.deepEqual(purchaseEmptyShortages([{ ...line, bottle_quantity: 100 }], [{ item_id: 'item', empty_quantity: 0, lpg_brands: null, size_kg: 12 }]), []);
});

test('invoice components and overhead retain exact cents', () => {
  const line = purchaseDraft(purchase).items[0];
  assert.deepEqual(purchaseTotals([{ ...line, quantity: 3, bottle_quantity: 1, unit_price: 0.1, bottle_unit_price: 0.2 }], 0.1, 0.1), { subtotal: 0.5, company_payable: 0.5, total_cost: 0.7 });
  assert.equal(validatePurchaseDraft(emptyPurchaseDraft()), null);
});

test('dispatch, receipt, payment and cancellation remain independently guarded', () => {
  assert.equal(purchaseAccess(purchase).dispatch, true); assert.equal(purchaseAccess(purchase).pay, false);
  const transit = purchaseAccess({ ...purchase, status: 'in_transit', payment_status: 'partial' }, true, true);
  assert.equal(transit.receive, true); assert.equal(transit.pay, true); assert.equal(transit.financials, false); assert.equal(transit.products, false);
  const prepaid = purchaseAccess({ ...purchase, status: 'in_transit', payment_status: 'paid' });
  assert.equal(prepaid.receive, true); assert.equal(prepaid.pay, false);
  assert.equal(purchaseAccess({ ...purchase, status: 'received' }, true, true).cancel, false);
  assert.equal(purchaseAccess({ ...purchase, status: 'received', business_category: 'stove' }, true, true).cancel, true);
  for (const status of ['created', 'in_transit', 'received', 'cancelled'] as const) {
    const access = purchaseAccess({ ...purchase, status }, false);
    assert.equal(access.editable, false); assert.equal(access.dispatch, false); assert.equal(access.receive, false); assert.equal(access.pay, false);
  }
});

test('inventory history distinguishes custody from filled receipt', () => {
  assert.equal(inventoryMovementLabel({ reference_type: 'purchase_dispatch', movement_type: 'purchase' }), 'Purchase dispatch');
  assert.equal(inventoryMovementLabel({ reference_type: 'purchase_receipt', movement_type: 'purchase' }), 'Filled cylinders received');
});
