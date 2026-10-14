import { test } from 'node:test';
import assert from 'node:assert/strict';
import { emptyPurchaseDraft, purchaseAccess, purchaseDraft, purchaseTotals, validatePurchaseDraft } from '../src/lib/purchase.ts';
import { inventoryMovementLabel } from '../src/lib/inventoryMovement.ts';
import type { Purchase } from '../src/types/purchase.ts';

const purchase: Purchase = {
  purchase_id: 'purchase', plant_id: 'plant', plant_name: 'Plant', brand_id: 'brand', company_name: 'Company',
  truck_id: 'truck', truck_name: 'Truck', status: 'created', payment_status: 'unpaid', commission: 50,
  subtotal: 800, company_payable: 750, transport_cost: 20, labour_cost: 10, total_cost: 780, notes: '', receipt_notes: null,
  created_at: '2026-10-14T00:00:00Z', dispatched_at: null, received_at: null, paid_at: null, revision: 1, legacy_record: false,
  items: [
    { purchase_item_id: 'refill', item_id: 'item', brand_name: 'Company', size_kg: 12, mouth_size: '22mm', type: 'refill', quantity: 4, empty_dispatched: 6, billed_quantity: 4, received_quantity: null, unit_price: 100, line_total: 400 },
    { purchase_item_id: 'new', item_id: 'item', brand_name: 'Company', size_kg: 12, mouth_size: '22mm', type: 'package', quantity: 2, empty_dispatched: 0, billed_quantity: 2, received_quantity: null, unit_price: 200, line_total: 400 },
  ],
};

test('Created allows a plant-only draft and separate refill/new lines for one SKU', () => {
  assert.equal(validatePurchaseDraft(emptyPurchaseDraft(),0),null);
  assert.equal(validatePurchaseDraft(purchaseDraft(purchase),800),null);
  assert.equal(purchaseAccess(purchase).products,true);
});

test('commission reduces company payable; logistics stay separate', () => {
  const draft=purchaseDraft(purchase);
  assert.deepEqual(purchaseTotals(draft.items,50,20,10),{ subtotal:800, company_payable:750,total_cost:780 });
  const fractional=[{ ...draft.items[0],quantity:3,unit_price:0.1 }];
  assert.deepEqual(purchaseTotals(fractional,0.1,0.1,0),{ subtotal:0.3,company_payable:0.2,total_cost:0.3 });
});

test('Created quantity edits update totals; unpaid receipt uses billed actual quantities', () => {
  const draft=purchaseDraft(purchase);
  draft.items[0].quantity=10;
  assert.equal(purchaseTotals(draft.items,0,0,0,purchase).subtotal,1400);
  const received={ ...purchase,status:'received' as const,items:purchase.items.map(i=>({ ...i,billed_quantity:1,received_quantity:1 })) };
  assert.equal(purchaseTotals(draft.items,0,0,0,received).subtotal,300);
});

test('prepaid discrepancies preserve settled billed quantities', () => {
  const paid={ ...purchase,status:'received' as const,payment_status:'paid' as const,
    items:purchase.items.map(i=>({ ...i,received_quantity:1 })) };
  assert.equal(purchaseTotals(purchaseDraft(paid).items,50,20,10,paid).total_cost,780);
  assert.equal(purchaseAccess(paid).editable,false);
});

test('actions follow lifecycle and independent payment status', () => {
  const created=purchaseAccess(purchase);
  assert.equal(created.dispatch,true); assert.equal(created.receive,false); assert.equal(created.pay,false);
  const transit=purchaseAccess({ ...purchase,status:'in_transit' });
  assert.equal(transit.products,false); assert.equal(transit.financials,true); assert.equal(transit.receive,true); assert.equal(transit.pay,true);
  const prepaid=purchaseAccess({ ...purchase,status:'in_transit',payment_status:'paid' });
  assert.equal(prepaid.editable,true); assert.equal(prepaid.financials,false); assert.equal(prepaid.receive,true); assert.equal(prepaid.pay,false);
  const received=purchaseAccess({ ...purchase,status:'received' });
  assert.equal(received.pay,true); assert.equal(received.receive,false); assert.equal(received.financials,true);
});

test('read-only capability and cancelled history expose no mutations', () => {
  for (const status of ['created','in_transit','received','cancelled'] as const) {
    const access=purchaseAccess({ ...purchase,status },false);
    assert.equal(access.editable,false); assert.equal(access.dispatch,false); assert.equal(access.receive,false); assert.equal(access.pay,false);
  }
  assert.equal(purchaseAccess({ ...purchase,status:'cancelled' }).editable,false);
});

test('validation catches duplicate lines, bad quantities and excessive commission', () => {
  const draft=purchaseDraft(purchase);
  assert.match(validatePurchaseDraft({ ...draft,items:[draft.items[0],draft.items[0]] },800) ?? '',/one refill/);
  assert.match(validatePurchaseDraft({ ...draft,commission:801 },800) ?? '',/subtotal/);
  assert.match(validatePurchaseDraft({ ...draft,items:[{ ...draft.items[0],quantity:1.5 }] },800) ?? '',/whole/);
  assert.match(validatePurchaseDraft({ ...draft,items:[{ ...draft.items[1],empty_dispatched:1 }] },800) ?? '',/empties/);
  assert.match(validatePurchaseDraft({ ...draft,transport_cost:Infinity },800) ?? '',/valid/);
});

test('inventory history identifies dispatch, new receipt and refill receipt', () => {
  assert.equal(inventoryMovementLabel({ movement_type:'purchase',reference_type:'purchase_dispatch' }),'Purchase dispatch');
  assert.equal(inventoryMovementLabel({ movement_type:'purchase',reference_type:'purchase_receipt_new' }),'New cylinders received');
  assert.equal(inventoryMovementLabel({ movement_type:'refill',reference_type:'purchase_receipt_refill' }),'Refills received');
  assert.equal(inventoryMovementLabel({ movement_type:'sale',reference_type:'sale' }),'Sale');
});
