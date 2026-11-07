import test from 'node:test';
import assert from 'node:assert/strict';
import { stockDisplay, movementDisplay } from '../src/lib/stockDisplay.ts';
import { saleDisplay } from '../src/lib/saleDisplay.ts';
import type { SaleTransaction } from '../src/types/sale.ts';

test('presentation derives cylinder balances from independent quantities', () => {
  assert.deepEqual(stockDisplay({ gas_quantity: 5, bottle_quantity: 8, unit_quantity: 0 }), {
    gas_quantity: 5, bottle_quantity: 8, unit_quantity: 0, filled_quantity: 5, empty_quantity: 3,
  });
  assert.equal(stockDisplay({ gas_quantity: 0, bottle_quantity: 0, unit_quantity: 4 }).filled_quantity, 4);
  const dispatch = movementDisplay({ gas_change: 0, bottle_change: -4, unit_change: 0 });
  assert.equal(dispatch.empty_quantity_change, -4);
  const receipt = movementDisplay({ gas_change: 5, bottle_change: 5, unit_change: 0 });
  assert.equal(receipt.filled_quantity_change, 5); assert.equal(receipt.empty_quantity_change, 0);
});

test('expected-empty rows are frontend only and never add a billed amount', () => {
  const sale: SaleTransaction = { sale_id: 'sale', sale_tier: 'retail', created_at: '', subtotal: 3200,
    total_amount: 3200, discount_amount: 0, exchange_fee: 0, business_category: 'lpg',
    sale_items: [{ item_id: 'product', type: 'refill', quantity: 2, unit_price: 900, line_total: 1800 },
      { item_id: 'product', type: 'package', quantity: 1, unit_price: 1400, line_total: 1400 }],
  };
  const display = saleDisplay(sale);
  assert.equal(sale.sale_items?.length, 2, 'source agreement remains unchanged');
  assert.equal(display.sale_items?.length, 3);
  assert.deepEqual(display.sale_items?.at(-1), { item_id: 'product', type: 'empty_return', quantity: 2, unit_price: 0, line_total: 0 });
  assert.equal(display.sale_items?.reduce((sum, row) => sum + row.line_total, 0), 3200);
  assert.strictEqual(saleDisplay({ ...sale, business_category: 'stove' }).sale_items, sale.sale_items);
});
