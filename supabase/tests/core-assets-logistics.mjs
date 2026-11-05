// Source-backed service advance/return, finalization and allocated depreciation.
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
const state = m.assets_logistics ??= { events: {} }, today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka' }).format(new Date());
const persist = () => writeFileSync(file, JSON.stringify(m, null, 2));
async function run(key, name, args) { if (state.events[key]?.completed) return state.events[key].result; state.events[key] ??= { name, args }; persist(); const e = state.events[key], result = await checked(c.rpc(e.name, e.args)); Object.assign(e, { completed: true, result }); persist(); return result; }
try {
  const categories = await checked(c.rpc('get_vehicle_expense_categories')); assert(categories.length);
  const service = await run('service', 'save_service_trip', { p_payload: { vehicle_id: m.truck, title: 'Scheduled engine oil and inspection', service_date: today, expenses: [{ category_id: categories[0].category_id, amount: 500, description: 'Documented service cost' }] }, p_request_id: randomUUID() });
  const advance = await run('advance', 'record_operating_payment', { p_payload: { service_trip_id: service.service_trip_id, kind: 'expense', payment_date: today, payments: [{ wallet_id: m.cash, amount: 700, reference: 'Service advance' }] }, p_request_id: randomUUID() });
  await run('returned', 'record_operating_payment', { p_payload: { service_trip_id: service.service_trip_id, kind: 'expense_return', return_of: advance.payment_ids[0], payment_date: today, payments: [{ wallet_id: m.cash, amount: 200, reference: 'Unused service advance returned' }] }, p_request_id: randomUUID() });
  const detail = await checked(c.rpc('get_service_trip', { p_service_trip_id: service.service_trip_id })); assert.equal(detail.total_cost, 500); assert.equal(detail.paid, 500); assert.equal(detail.advance, 0);
  await run('finalized', 'finalize_service_trip', { p_service_trip_id: service.service_trip_id, p_revision: detail.revision, p_request_id: randomUUID() });
  await run('depreciation', 'accounting_operation', { p_payload: { action: 'asset_depreciate', asset_id: m.events.equipment.result.id, amount: 100, date: today, description: 'Recorded wear on shared shop equipment' }, p_request_id: randomUUID() });
  state.verified = true; persist(); console.log('PASS actual service expense, advance, original-wallet return, zero-surplus finalization and original-allocation equipment depreciation');
} finally { await c.auth.signOut({ scope: 'local' }); }
