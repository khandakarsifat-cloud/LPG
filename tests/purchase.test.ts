import { test } from 'node:test';
import assert from 'node:assert/strict';
import { emptyPurchaseDraft, purchaseAccess, purchaseDraft, purchaseTotals, purchaseEmptyShortages, validatePurchaseDraft } from '../src/lib/purchase.ts';
import { inventoryMovementLabel } from '../src/lib/inventoryMovement.ts';
import type { Purchase } from '../src/types/purchase.ts';
import { describePurchaseActivity } from '../src/lib/purchaseActivity.ts';

const purchase: Purchase = {
  purchase_id: 'purchase', plant_id: 'plant', plant_name: 'Plant', brand_id: 'brand', company_name: 'Company',
  vehicle_id: 'vehicle', vehicle_name: 'Vehicle', status: 'created', payment_status: 'unpaid', commission: 50,
  subtotal: 800, company_payable: 750, transport_cost: 20, labour_cost: 10, total_cost: 780, notes: '', receipt_notes: null,
  created_at: '2026-10-14T00:00:00Z', dispatched_at: null, received_at: null, paid_at: null, revision: 1,
  items: [
    { purchase_item_id: 'refill', item_id: 'item', brand_name: 'Company', size_kg: 12, mouth_size: '22mm', type: 'refill', quantity: 4, empty_dispatched: 6, billed_quantity: 4, received_quantity: null, unit_price: 100, line_total: 400 },
    { purchase_item_id: 'new', item_id: 'item', brand_name: 'Company', size_kg: 12, mouth_size: '22mm', type: 'package', quantity: 2, empty_dispatched: 0, billed_quantity: 2, received_quantity: null, unit_price: 200, line_total: 400 },
  ],
};

test('activity describes financial, note and vehicle changes without substituting current amounts', () => {
  const summary = describePurchaseActivity({ activity_id: 'a', action: 'updated', actor_name: 'Operator', created_at: '', details: {
    before: { commission: '10', notes: 'old', vehicle_id: null },
    after: { commission: 20, notes: 'Bring refills', vehicle_id: 'vehicle' },
  } }, purchase);
  assert.deepEqual(summary.changes, ['Commission: Tk 10.00 → Tk 20.00', 'Vehicle assigned: Vehicle', 'Notes updated: Bring refills']);
  assert.ok(!summary.changes.join(' ').includes('Tk 50.00'));
});

test('unified activity renders ledger evidence once without repeating payment detail lines', () => {
  const summary = describePurchaseActivity({ activity_id: 'a', action: 'payment_recorded', actor_name: 'Operator', created_at: '',
    wallet_entries: [{ transaction_id: 'ledger', wallet_name: 'Cash', method: 'cash', amount: -50, type: 'purchase_payment_company', created_at: '', operation_id: 'operation', description: 'Company payment', reference: null, component: 'company', actor: 'Operator', obligation_id: null }],
    details: { paid_amount: 50, due: 730, payments: [{ wallet_name: 'Cash', amount: 50, component: 'company', payment_id: 'payment' }] },
  }, purchase);
  assert.deepEqual(summary.changes, ['Total paid: Tk 50.00', 'Outstanding: Tk 730.00']);
});

test('activity compares product quantities, prices, empties, additions and removals by SKU and type', () => {
  const summary = describePurchaseActivity({ activity_id: 'a', action: 'updated', actor_name: '', created_at: '', details: {
    before_items: [{ item_id: 'item', type: 'refill', quantity: 4, empty_dispatched: 4, unit_price: 100 },
      { item_id: 'removed', type: 'package', quantity: 1 }],
    items: [{ item_id: 'item', type: 'refill', quantity: 5, empty_dispatched: 5, unit_price: 110 },
      { item_id: 'item', type: 'package', quantity: 2, unit_price: 200 }],
  } }, purchase);
  assert.ok(summary.changes.some(line => line.includes('quantity: 4 → 5')));
  assert.ok(summary.changes.some(line => line.includes('price: Tk 100.00 → Tk 110.00')));
  assert.ok(summary.changes.some(line => line.includes('empties: 4 → 5')));
  assert.ok(summary.changes.some(line => line.startsWith('Added Company 12 kg 22mm new cylinders')));
  assert.ok(summary.changes.some(line => line.startsWith('Removed Product new cylinders')));
});

test('older activity shows saved products without claiming an unknown product change', () => {
  const summary = describePurchaseActivity({ activity_id: 'a', action: 'updated', actor_name: '', created_at: '', details: {
    items: [{ item_id: 'item', type: 'refill', quantity: 4, unit_price: 90 }],
  } }, purchase);
  assert.match(summary.changes[0], /earlier product values were not captured/);
  assert.match(summary.snapshots[0], /4 × Tk 90.00/);
});

test('activity handles notes-only saves, no-op saves, payment and lifecycle evidence', () => {
  const describe = (action: string, details: Record<string, unknown>) => describePurchaseActivity({ activity_id: 'a', action, details, actor_name: '', created_at: '' }, purchase);
  assert.deepEqual(describe('updated', { before: { notes: 'old' }, after: { notes: '' } }).changes, ['Notes cleared']);
  assert.deepEqual(describe('updated', { before: { commission: '5.00' }, after: { commission: 5 } }).changes, ['Purchase saved; no recorded field changes.']);
  assert.deepEqual(describe('paid', { total_cost: '123', company_payable: 100 }).changes, ['Company payment: Tk 100.00', 'Settled total: Tk 123.00']);
  assert.deepEqual(describe('dispatched', { empty_cylinders: 4 }).changes, ['4 empty cylinders dispatched']);
  assert.deepEqual(describe('logistics_updated', { operating_cost: 0 }).changes, ['Operating costs: Tk 0']);
  assert.deepEqual(describe('cancelled', { previous_status: 'in_transit', notes: 'Stock reversed' }).changes, ['Cancelled from in transit.', 'Stock reversed']);
  assert.equal(describe('future_event', {}).title, 'Purchase activity');
});

test('all refill shortages are grouped by product and new cylinders do not consume empties', () => {
  const lines = purchaseDraft(purchase).items;
  const inventory = [{ item_id: 'item', lpg_brands: { brand_name: 'Company' }, size_kg: 12, mouth_size: '22mm', empty_quantity: 2 },
    { item_id: 'second', lpg_brands: { brand_name: 'Company' }, size_kg: 25, empty_quantity: 0 }];
  const shortages = purchaseEmptyShortages([...lines, { ...lines[0], item_id: 'second', quantity: 3 }], inventory);
  assert.deepEqual(shortages.map(s => [s.required, s.available, s.missing]), [[4, 2, 2], [3, 0, 3]]);
  assert.deepEqual(purchaseEmptyShortages(lines.filter(l => l.type === 'package'), inventory), []);
});

test('only owners can cancel Created or In Transit purchases; receipt is permanent', () => {
  assert.equal(purchaseAccess({ ...purchase, status: 'received', payment_status: 'paid' }, true, true).cancel, false);
  assert.equal(purchaseAccess({ ...purchase, status: 'received' }, true, true).cancel, false);
  assert.equal(purchaseAccess({ ...purchase, status: 'cancelled' }, true, true).cancel, false);
  assert.equal(purchaseAccess(purchase, false, true).cancel, false);
  assert.equal(purchaseAccess(purchase, true, false).cancel, false);
  assert.equal(purchaseAccess(purchase, true, true).cancel, true);
  assert.equal(purchaseAccess({ ...purchase, status: 'in_transit', payment_status: 'partial' }, true, true).cancel, true);
});

test('partial payments lock financials while receiving and additional payments stay independent', () => {
  const access = purchaseAccess({ ...purchase, status: 'in_transit', payment_status: 'partial', paid_amount: 100 });
  assert.equal(access.financials, false); assert.equal(access.pay, true); assert.equal(access.receive, true);
  assert.equal(purchaseAccess({ ...purchase, status: 'in_transit', payment_status: 'partial' }, true, true, false).financials, true);
});

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
  assert.equal(received.pay,true); assert.equal(received.receive,false); assert.equal(received.financials,false);
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

test('Created drafts restore exchange quantities; saved dispatched history remains independent', () => {
  assert.equal(purchaseDraft(purchase).items[0].empty_dispatched, 4);
  const dispatched = { ...purchase, status: 'in_transit' as const };
  assert.equal(purchaseDraft(dispatched).items[0].empty_dispatched, 6);
  assert.match(validatePurchaseDraft({ ...emptyPurchaseDraft(), items: [{ ...purchaseDraft(purchase).items[0], empty_dispatched: 6 }] }, 400) ?? '', /one empty/);
});

test('stove purchases receive directly and retain guarded owner cancellation after receipt', () => {
 const stove = { ...purchase, business_category: 'stove' as const, transport_cost: 0 };
 const created = purchaseAccess(stove, true, true);
 assert.equal(created.dispatch, false); assert.equal(created.receive, true); assert.equal(created.pay, true);
 const received = purchaseAccess({ ...stove, status: 'received', payment_status: 'paid' }, true, true);
 assert.equal(received.cancel, true); assert.equal(received.products, false); assert.equal(received.financials, false);
 assert.equal(purchaseAccess({ ...stove, status: 'received' }, true, false).cancel, false);
 const prepaid = purchaseAccess({ ...stove, payment_status: 'partial' });
 assert.equal(prepaid.products, false); assert.equal(prepaid.financials, false); assert.equal(prepaid.receive, true);
 const delivery = { ...stove, transport_cost: 1000 };
 assert.equal(purchaseAccess(delivery).dispatch, true);
 assert.equal(purchaseAccess(delivery).receive, false);
 assert.equal(purchaseAccess({ ...delivery, status: 'in_transit' }).receive, true);
});
