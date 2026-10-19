import assert from 'node:assert/strict';
import test from 'node:test';
import { customerDisplayName, customerPeriod, customerActivityFilterCount, defaultCustomerFilters } from '../src/lib/customer.ts';
import { readAllRows } from '../src/lib/queryPages.ts';

test('Customer display identity uses a wholesale shop and retains a retail personal name', () => {
  assert.equal(customerDisplayName({ name: 'Contact', shop_name: 'Shop', tier: 'wholesale' }), 'Shop');
  assert.equal(customerDisplayName({ name: 'Contact', shop_name: 'Shop', tier: 'retail' }), 'Contact');
  assert.equal(customerDisplayName({ name: 'Contact', shop_name: '', tier: 'wholesale' }), 'Contact');
});
test('Customer periods use Dhaka days, Saturday weeks and calendar-month starts', () => {
  assert.deepEqual(customerPeriod('week', new Date('2026-10-16T18:01:00Z')), { from: '2026-10-17', to: '2026-10-17' });
  assert.deepEqual(customerPeriod('week', new Date('2026-10-16T17:59:00Z')), { from: '2026-10-10', to: '2026-10-16' });
  assert.deepEqual(customerPeriod('month', new Date('2026-10-31T18:01:00Z')), { from: '2026-11-01', to: '2026-11-01' });
  assert.deepEqual(customerPeriod('all'), { from: '', to: '' });
});
test('Activity filter count groups min/max and counts an explicit empty product selection', () => {
  assert.equal(customerActivityFilterCount(defaultCustomerFilters), 0);
  assert.equal(customerActivityFilterCount({ ...defaultCustomerFilters, from: '2026-10-01', to: '2026-10-19', transactions_min: '0', transactions_max: '5', item_ids: [] }), 3);
});
test('Batched catalog/customer reads do not silently lose records past the server limit', async () => {
  const all = Array.from({ length: 1234 }, (_, n) => n);
  const ranges: number[][] = [];
  const rows = await readAllRows<number>(async (from, to) => { ranges.push([from, to]); return { data: all.slice(from, to + 1), error: null }; });
  assert.deepEqual(rows, all);
  assert.deepEqual(ranges, [[0, 499], [500, 999], [1000, 1499]]);
});
test('A failed later batch rejects instead of returning incomplete customer/catalog totals', async () => {
  const error = new Error('Later page unavailable');
  await assert.rejects(readAllRows<number>(async from => from === 0 ? { data: [1, 2], error: null } : { data: null, error }, 2), error);
});
