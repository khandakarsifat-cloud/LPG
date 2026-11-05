// Current shared purchase/POS engine: direct credit receipt and split partial sale.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--vps'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8')), s = parseEnv(readFileSync('.env.core-test', 'utf8'));
assert.equal(f.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io');
const file = '.temp/core-business/manifest.json', m = JSON.parse(readFileSync(file, 'utf8')); assert(m.verified_at);
const c = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const checked = async p => { const { data, error } = await p; if (error) throw Error(error.message); return data; };
await checked(c.auth.signInWithPassword({ email: s.LPG_TEST_EMAIL, password: s.LPG_TEST_PASSWORD }));
const state = m.stove_acceptance ??= { events: {} }; const persist = () => writeFileSync(file, JSON.stringify(m, null, 2));
async function run(key, name, args) { if (state.events[key]?.completed) return state.events[key].result; state.events[key] ??= { name, args }; persist(); const e = state.events[key]; const result = await checked(c.rpc(e.name, e.args)); Object.assign(e, { completed: true, result }); persist(); return result; }
try {
  const purchase = await run('purchase', 'create_purchase', { p_payload: { business_category: 'stove', request_id: randomUUID(), supplier_name: 'Dhaka appliance wholesale', transport_cost: 0, labour_cost: 100, notes: 'Direct credit receipt of five stoves', items: [{ item_id: m.stove, quantity: 5, bottle_quantity: 0, unit_price: 1500, bottle_unit_price: 0 }] } });
  const detail = (await checked(c.rpc('get_purchases_by_ids', { p_ids: [purchase.purchase_id] })))[0];
  await run('receipt', 'receive_purchase', { p_purchase_id: purchase.purchase_id, p_revision: detail.revision }); state.received = true; persist();
  await run('prices', 'save_product_prices', { p_item_id: m.stove, p_customer_tier: 'retail', p_prices: { refill: { price: 0, mrp: null }, package: { price: 2500, mrp: null } }, p_expected: { refill: null, package: null } });
  const customer = await checked(c.from('customers').select('customer_id').eq('phone', '01799000402').single());
  await run('sale', 'create_pos_sale', { p_customer_phone: '01799000402', p_customer_name: 'Karim retail store', p_customer_shop_name: null, p_customer_address: 'Mirpur Dhaka', p_customer_tier: 'retail', p_customer_id: customer.customer_id, p_discount_amount: 0, p_exchange_fee: 0, p_notes: 'Two stoves; partial split payment', p_items: [{ item_id: m.stove, type: 'package', quantity: 2, unit_price: 2500 }], p_payments: [{ wallet_id: m.cash, amount: 1000 }, { wallet_id: m.bank, amount: 1000 }], p_request_id: randomUUID() }); state.sold = true; persist();
  const inventory = await checked(c.rpc('get_product_inventory', { p_item_id: m.stove })); assert.equal(inventory.valuation.filled_quantity, 3); assert.equal(inventory.valuation.filled_value, 4560);
  console.log('PASS current Stove direct receipt, invoice/labour FIFO, shared POS, split partial payment and remaining physical/value stock');
} finally { await c.auth.signOut({ scope: 'local' }); }
