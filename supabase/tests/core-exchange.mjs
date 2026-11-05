// Retain the exact 2 Jamuna /1 Jamuna /1 Total scenario at changed current prices.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--vps'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8')), s = parseEnv(readFileSync('.env.core-test', 'utf8'));
assert.equal(f.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io');
const file = '.temp/core-business/manifest.json', m = JSON.parse(readFileSync(file, 'utf8'));
const c = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const checked = async p => { const { data, error } = await p; if (error) throw Error(error.message); return data; };
await checked(c.auth.signInWithPassword({ email: s.LPG_TEST_EMAIL, password: s.LPG_TEST_PASSWORD }));
try {
  assert(m.browser_requests['reference-bottle'].completed);
  const customer = await checked(c.from('customers').select('customer_id').eq('phone', '01799000402').single());
  m.exchange_acceptance ??= { args: { p_customer_phone: '01799000402', p_customer_name: 'Karim retail store', p_customer_shop_name: null, p_customer_address: 'Mirpur Dhaka', p_customer_tier: 'retail', p_customer_id: customer.customer_id, p_discount_amount: 0, p_exchange_fee: 50, p_notes: 'Retained 2/1/1 scenario: actual historical FIFO, new Jamuna1900 and Total2000 replacement bases', p_items: [{ item_id: m.jamuna, type: 'refill', quantity: 2, unit_price: 1250 }, { item_id: m.jamuna, type: 'empty_return', quantity: 1, unit_price: 0 }, { item_id: m.total, type: 'empty_return', quantity: 1, unit_price: 0 }], p_payments: [{ wallet_id: m.cash, amount: 1000 }], p_request_id: randomUUID() } };
  writeFileSync(file, JSON.stringify(m, null, 2));
  const result = await checked(c.rpc('create_pos_sale', m.exchange_acceptance.args));
  Object.assign(m.exchange_acceptance, { completed: true, result }); writeFileSync(file, JSON.stringify(m, null, 2));
  assert.deepEqual(await checked(c.rpc('create_pos_sale', m.exchange_acceptance.args)), result);
  const j = await checked(c.rpc('get_product_inventory', { p_item_id: m.jamuna })), t = await checked(c.rpc('get_product_inventory', { p_item_id: m.total }));
  assert.equal(j.valuation.empty_value, 1900); assert.equal(t.valuation.empty_value, 2000);
  console.log('PASS retained 2/1/1 exchange at new brand prices, original FIFO costs, optional exchange fee, partial payment and exact retry');
} finally { await c.auth.signOut({ scope: 'local' }); }
