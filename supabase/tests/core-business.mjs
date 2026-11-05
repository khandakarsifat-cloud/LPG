// Retained current-model acceptance lab. All business writes use real Auth/PostgREST.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { provisionTestBusiness } from './trusted-test-provisioning.mjs';

assert(process.argv.includes('--vps'), 'Explicit primary VPS required');
const front = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const back = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(front.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io');
assert.equal(back.VPS_HOST, '144.79.249.4'); assert.equal(back.VPS_PROJECT_DIR, '/opt/lpg');
const folder = '.temp/core-business'; mkdirSync(folder, { recursive: true });
const path = `${folder}/manifest.json`;
const ssh = [...(back.VPS_SSH_KEY ? ['-i', back.VPS_SSH_KEY] : []), '-p', back.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${back.VPS_USER}@${back.VPS_HOST}`];
const sql = input => execFileSync('ssh', [...ssh, 'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
const c = createClient(front.VITE_SUPABASE_URL, front.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const checked = async promise => { const { data, error } = await promise; if (error) throw Error(`${error.code}: ${error.message}`); return data; };
let m;
if (!existsSync(path)) {
  assert.equal(sql("select count(*) from public.tenants"), '0', 'Establish only the explicitly reset empty baseline');
  const email = `core-lab-${randomUUID().slice(0, 8)}@example.invalid`, password = randomUUID() + 'Aa9!';
  writeFileSync('.env.core-test', `LPG_TEST_EMAIL=${email}\nLPG_TEST_PASSWORD=${password}\n`);
  const identity = await provisionTestBusiness(c, { email, password, businessName: 'LPG Component Development Lab 2026-11-04', ownerName: 'Core acceptance owner' });
  m = { tenant_id: identity.tenant_id, user_id: identity.user.id, events: {}, started_at: new Date().toISOString() };
} else {
  m = JSON.parse(readFileSync(path, 'utf8'));
  const secrets = parseEnv(readFileSync('.env.core-test', 'utf8'));
  await checked(c.auth.signInWithPassword({ email: secrets.LPG_TEST_EMAIL, password: secrets.LPG_TEST_PASSWORD }));
}
const persist = () => writeFileSync(path, JSON.stringify(m, null, 2)); persist();
const uuid = value => { assert.match(value, /^[a-f0-9-]{36}$/); return `'${value}'::uuid`; };
assert.equal(sql(`select tenant_id from public.user_profiles where user_id=${uuid(m.user_id)}`), m.tenant_id);
if (m.verified_at) { await c.auth.signOut({ scope: 'local' }); await import('./core-independent.mjs'); process.exit(0); }
const run = async (key, name, args) => {
  if (m.events[key]?.completed) return m.events[key].result;
  if (!m.events[key]) { m.events[key] = { name, args, at: new Date().toISOString() }; persist(); }
  const event = m.events[key]; assert.equal(event.name, name);
  const result = await checked(c.rpc(name, event.args)); Object.assign(event, { completed: true, result }); persist(); return result;
};
const op = (key, payload) => run(key, 'accounting_operation', { p_payload: payload, p_request_id: randomUUID() });
const cashOp = (key, payload) => run(key, 'move_wallet_money', { p_payload: payload, p_request_id: randomUUID() });
const item = async (key, payload) => {
  if (m.events[key]) return m.events[key].result;
  const result = await checked(c.from('items').insert({ ...payload, tenant_id: m.tenant_id }).select('item_id').single());
  m.events[key] = { completed: true, result, at: new Date().toISOString() }; persist(); return result;
};
const one = async (table, column, id) => table === 'purchases' ? (await checked(c.rpc('get_purchases_by_ids', { p_ids: [id] })))[0] : table === 'transits' ? checked(c.rpc('get_transit', { p_transit_id: id })) : checked(c.from(table).select('*').eq(column, id).single());
const rev = async (id, kind = 'purchases') => (await one(kind, kind === 'purchases' ? 'purchase_id' : 'transit_id', id)).revision;
const revisionEvent = async (key, name, id, extra = {}) => run(key, name, { p_purchase_id: id, p_revision: await rev(id), ...extra });
const wallets = await checked(c.rpc('get_payment_wallets'));
m.cash = wallets.find(w => w.type === 'cash').wallet_id; m.bank = wallets.find(w => w.type === 'dealership').wallet_id; persist();
await cashOp('capital', { action: 'adjustment', wallet_id: m.cash, business: 'lpg', classification: 'capital', amount: 1000000, reason: 'Initial documented working capital' });
for (const [key, name] of [['jamuna', 'Jamuna'], ['total', 'Total Gas']]) {
  const brand = await run(`brand-${key}`, 'create_lpg_brand', { p_brand_name: name, p_description: 'Current component acceptance catalog' });
  const brandId = typeof brand === 'string' ? brand : brand.brand_id;
  m[key] = (await item(`item-${key}`, { brand_id: brandId, size_kg: 12, mouth_size: '22mm' })).item_id;
  if (key === 'jamuna') {
    const plant = await run('plant', 'create_gas_plant', { p_plant_name: 'Jamuna Dhaka filling plant', p_brand_id: brandId, p_location: 'Dhaka' });
    m.plant = typeof plant === 'string' ? plant : plant.plant_id;
  }
} persist();
const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka' }).format(new Date());
m.driver = (await run('driver', 'save_employee', { p_payload: { name: 'Rahim acceptance driver', employee_type_name: 'Driver', business_unit: 'truck_business', phones: [{ phone: '01799000401', is_primary: true }], terms: { effective_from: today, monthly_salary: 0, is_active: true } }, p_request_id: randomUUID() })).employee_id;
m.truck = (await run('truck', 'save_vehicle', { p_payload: { name: 'Core Dhaka delivery truck', serial_no: 'CORE-DHK-0401', capacity: 500, driver_employee_id: m.driver, book_value: 500000, funding: 'capital' }, p_request_id: randomUUID() })).vehicle_id; persist();
await run('opening-empties', 'adjust_inventory', { p_payload: { item_id: m.jamuna, kind: 'capital', filled_quantity: 0, empty_quantity: 70, empty_unit_cost: 1200, reason: 'Documented historical cylinder ownership' }, p_request_id: randomUUID() });
await run('total-reference', 'set_product_buying_price', { p_payload: { item_id: m.total, price_type: 'bottle', is_manual: true, price: 2000, reason: 'Current Total Gas bottle reference', expected: null }, p_request_id: randomUUID() });
const purchase = await run('purchase-main', 'create_purchase', { p_payload: { request_id: randomUUID(), plant_id: m.plant, vehicle_id: m.truck, labour_cost: 1300, transport_cost: 2600, notes: '100 Gas / 30 Bottle; 70 owned empties', items: [{ item_id: m.jamuna, quantity: 100, bottle_quantity: 30, unit_price: 800, bottle_unit_price: 1600 }] } });
m.purchase = purchase.purchase_id; persist();
assert.deepEqual(await checked(c.rpc('create_purchase', m.events['purchase-main'].args)), purchase);
await revisionEvent('dispatch-main', 'dispatch_purchase', m.purchase);
await revisionEvent('receive-main', 'receive_purchase', m.purchase);
const prices = { refill: { price: 1250, mrp: null }, package: { price: 3000, mrp: null } };
await run('sale-prices', 'save_product_prices', { p_item_id: m.jamuna, p_customer_tier: 'retail', p_prices: prices, p_expected: { refill: null, package: null } });
const lines = [{ item_id: m.jamuna, type: 'refill', quantity: 2, unit_price: 1250 }, { item_id: m.jamuna, type: 'empty_return', quantity: 1, unit_price: 0 }, { item_id: m.total, type: 'empty_return', quantity: 1, unit_price: 0 }];
const saleArgs = { p_customer_phone: '01799000402', p_customer_name: 'Karim retail store', p_customer_address: 'Mirpur Dhaka', p_customer_shop_name: null, p_customer_tier: 'retail', p_discount_amount: 0, p_exchange_fee: 0, p_notes: 'Two Jamuna refill: one Jamuna and one Total return', p_items: lines, p_request_id: randomUUID(), p_payments: [] };
const sale = await run('sale-211', 'create_pos_sale', saleArgs); m.sale = sale.sale_id; persist();
assert.deepEqual(await checked(c.rpc('create_pos_sale', m.events['sale-211'].args)), sale);
// Independent source expectations, before later scenarios change the balances.
if (!m.initial_verified) {
  const rows = JSON.parse(sql(`select json_build_object('j',(select row_to_json(x) from public.inventory_costs x where tenant_id=${uuid(m.tenant_id)} and item_id=${uuid(m.jamuna)}),'t',(select row_to_json(x) from public.inventory_costs x where tenant_id=${uuid(m.tenant_id)} and item_id=${uuid(m.total)}),'gain',(select sum(amount) from public.accounting_lines where tenant_id=${uuid(m.tenant_id)} and account='bottle_exchange'),'cash',(select sum(balance) from public.wallets where tenant_id=${uuid(m.tenant_id)}));`));
  assert.equal(rows.j.filled_quantity, 98); assert.equal(rows.j.empty_quantity, 1); assert.equal(rows.t.empty_quantity, 1);
  assert.equal(rows.j.empty_value, 1648.75); assert.equal(rows.t.empty_value, 2000); assert.equal(rows.gain, -1248.75); assert.equal(rows.cash, 1000000);
  m.initial_verified = true; persist();
}
await run('supplier-partial', 'record_purchase_payment', { p_purchase_id: m.purchase, p_payments: [{ wallet_id: m.cash, amount: 20000 }, { wallet_id: m.bank, amount: 10000 }], p_request_id: randomUUID() });
await run('customer-partial', 'collect_sale_payment', { p_sale_id: m.sale, p_payments: [{ wallet_id: m.bank, amount: 1000 }], p_request_id: randomUUID() });
await cashOp('treasury', { action: 'transfer', wallet_id: m.cash, destination_id: m.bank, amount: 8000, reason: 'Move real funds to bank' });
const loan = await op('loan', { action: 'loan_create', lender: 'Development cooperative', wallet_id: m.bank, amount: 3000, allocations: { stove: 100 }, date: today, description: 'Working capital principal' }); m.loan = loan.id;
await op('loan-repayment', { action: 'loan_repay', loan_id: m.loan, wallet_id: m.bank, amount: 500, date: today, description: 'Principal repayment' });
await run('bonus', 'employee_payment_operation', { p_payload: { action: 'pay', items: [{ employee_id: m.driver, kind: 'bonus', bonus_name: 'Safe delivery bonus', payment_date: today, payments: [{ wallet_id: m.cash, amount: 100 }] }] }, p_request_id: randomUUID() });
// Complete the received purchase journey, then exercise an external transit.
const linked = (await checked(c.rpc('get_transit_directory', { p_filters: {}, p_offset: 0, p_limit: 100 }))).entries.find(t => t.purchase_id === m.purchase); assert(linked);
await run('complete-purchase-trip', 'transition_transit', { p_action: 'complete', p_transit_id: linked.transit_id, p_costs: { driver_cost: 0, helper_cost: 0, oil_cost: 0, others_cost: 0, additional_costs: [] }, p_revision: await rev(linked.transit_id, 'transits') });
const transit = await run('external-trip', 'create_custom_transit', { p_payload: { vehicle_id: m.truck, fee: 1000, client_name: 'Dhaka shop transport client', destination: 'Savar', description: 'External customer delivery' }, p_request_id: randomUUID() });
m.transit = transit.transit_id; persist();
await run('complete-external', 'transition_transit', { p_action: 'complete', p_transit_id: m.transit, p_costs: { driver_cost: 50, helper_cost: 0, oil_cost: 30, others_cost: 20, additional_costs: [] }, p_revision: await rev(m.transit, 'transits') });
assert.equal((await checked(c.rpc('transition_transit', m.events['complete-external'].args))).already_applied, true);
const conflict = await c.rpc('transition_transit', { ...m.events['complete-external'].args, p_costs: { ...m.events['complete-external'].args.p_costs, oil_cost: 31 } }); assert(conflict.error, 'Changed completion intent must reject');
if (!m.extended_started) {
const reports = {};
for (const category of ['lpg', 'stove', 'logistics', 'all']) {
  const report = await checked(c.rpc('get_finance_analysis', { p_filters: { from: today, to: today, category, grain: 'day' } }));
  for (const side of ['opening', 'closing']) assert(Math.abs(report[side].assets - report[side].liabilities - report[side].equity) < .001, `${category}/${side} equation`);
  assert.equal(report.business_positions.length, 4); reports[category] = report;
}
const evidence = JSON.parse(sql(`select json_build_object('journal_imbalances',(select count(*) from(select journal_id from public.accounting_lines where tenant_id=${uuid(m.tenant_id)} group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0)x),'wallet_mismatches',(select count(*) from public.wallets w where tenant_id=${uuid(m.tenant_id)} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)),'wallet_total',(select sum(balance) from public.wallets where tenant_id=${uuid(m.tenant_id)}),'cash',(select sum(amount) from public.accounting_lines where tenant_id=${uuid(m.tenant_id)} and account='cash'),'loan',(select outstanding from public.loans where loan_id=${uuid(m.loan)}),'transfer_legs',(select count(*) from public.wallet_transactions where operation_id=${uuid(m.events.treasury.args.p_request_id)}));`));
assert.equal(evidence.journal_imbalances, 0); assert.equal(evidence.wallet_mismatches, 0); assert.equal(evidence.wallet_total, evidence.cash); assert.equal(evidence.loan, 2500); assert.equal(evidence.transfer_legs, 2);
assert.equal(evidence.wallet_total, 974300); // 1m − 30k supplier + 1k collection + 2.5k loan −100 bonus +1k trip −100 trip costs.
assert.equal(reports.all.totals.transfers, 8000);
writeFileSync(`${folder}/verification.json`, JSON.stringify({ at: new Date().toISOString(), evidence, reports }, null, 2));
m.extended_started = true; persist();
}
// Original-layer cancellation and a separate, retained paid package invoice.
await run('cancel-211', 'reverse_sale', { p_sale_id: m.sale, p_reason: 'Customer returned the exact original goods and bottles', p_confirmation: 'CANCEL', p_request_id: randomUUID() });
await run('refund-211', 'refund_sale', { p_sale_id: m.sale, p_payments: [{ wallet_id: m.bank, amount: 1000 }], p_request_id: randomUUID() });
const savedCustomer = await checked(c.from('customers').select('customer_id').eq('phone', saleArgs.p_customer_phone).single());
if (m.events['package-sale'] && !m.events['package-sale'].completed) { m.events['package-sale'].args.p_customer_id = savedCustomer.customer_id; persist(); }
const packageSale = await run('package-sale', 'create_pos_sale', { ...saleArgs, p_customer_id: savedCustomer.customer_id, p_notes: 'Package transfers both gas and cylinder ownership', p_items: [{ item_id: m.jamuna, type: 'package', quantity: 3, unit_price: 3000 }], p_request_id: randomUUID(), p_payments: [{ wallet_id: m.cash, amount: 4000 }] }); m.package_sale = packageSale.sale_id;
// Stove returns settle source-backed refund obligations; internal transport is not refunded as cash.
const stoveTypes = await checked(c.rpc('get_stove_product_types')); assert(stoveTypes.length);
m.stove = (await run('stove', 'save_stove_product', { p_payload: { name: 'Two burner stainless acceptance stove', type_id: stoveTypes[0].type_id }, p_request_id: randomUUID() })).item_id;
const sp = await run('stove-purchase-returned', 'create_purchase', { p_payload: { request_id: randomUUID(), business_category: 'stove', supplier_name: 'Dhaka appliance wholesale', vehicle_id: m.truck, transport_cost: 200, labour_cost: 100, items: [{ item_id: m.stove, quantity: 3, bottle_quantity: 0, unit_price: 1500, bottle_unit_price: 0 }] } });
await revisionEvent('stove-dispatch', 'dispatch_purchase', sp.purchase_id);
await revisionEvent('stove-receipt', 'receive_purchase', sp.purchase_id);
await run('stove-payment', 'record_purchase_payment', { p_purchase_id: sp.purchase_id, p_payments: [{ wallet_id: m.cash, amount: 1000 }], p_request_id: randomUUID() });
await revisionEvent('stove-cancel', 'initiate_purchase_cancellation', sp.purchase_id, { p_confirmation: 'CANCEL', p_request_id: randomUUID() });
const obligation = (await checked(c.rpc('get_purchase_settlement', { p_purchase_id: sp.purchase_id }))).obligations[0]; assert(obligation);
await run('stove-refund', 'refund_purchase', { p_purchase_id: sp.purchase_id, p_obligation_id: obligation.obligation_id, p_payments: [{ wallet_id: m.bank, amount: 1000 }], p_request_id: randomUUID() });
await op('equipment', { action: 'asset_register', name: 'Shop weighing scale and office equipment', kind: 'equipment', funding: 'wallet', wallet_id: m.cash, amount: 10000, date: today, description: 'Documented equipment purchase', allocations: { lpg: 70, stove: 30 } });
// Unknown/obsolete purchase representations and failed edits leave the complete business untouched.
const bad = await c.rpc('create_purchase', { p_payload: { request_id: randomUUID(), plant_id: m.plant, items: [{ item_id: m.jamuna, quantity: 0, bottle_quantity: 1, unit_price: 0, bottle_unit_price: 1700 }] } }); assert(bad.error, 'Bottle-only purchase must reject');
const stock = await one('items', 'item_id', m.jamuna); assert.equal(stock.filled_quantity, 97); assert.equal(stock.empty_quantity, 0);
if (!m.financial_extensions_started) {
const final = JSON.parse(sql(`select json_build_object('wallet',(select sum(balance) from public.wallets where tenant_id=${uuid(m.tenant_id)}),'cash',(select sum(amount) from public.accounting_lines where tenant_id=${uuid(m.tenant_id)} and account='cash'),'inventory',(select sum(consolidated_amount) from public.accounting_lines where tenant_id=${uuid(m.tenant_id)} and account in('inventory_lpg','inventory_stove','inventory_transit')),'transit',(select coalesce(sum(consolidated_amount),0) from public.accounting_lines where tenant_id=${uuid(m.tenant_id)} and account='inventory_transit'),'stove',(select filled_quantity from public.items where item_id=${uuid(m.stove)}),'sale_cost',(select sum(amount) from public.accounting_lines where tenant_id=${uuid(m.tenant_id)} and entity_id=${uuid(m.package_sale)} and account='cogs'),'sale_internal_cost',(select sum(l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) join public.inventory_movements x on x.tenant_id=j.tenant_id and x.movement_id=j.source_id where j.tenant_id=${uuid(m.tenant_id)} and j.source='internal_cogs' and x.reference_id=${uuid(m.package_sale)} and l.account='cogs'));`));
assert.equal(final.wallet, 967300); assert.equal(final.cash, final.wallet); assert.equal(final.inventory, 207275.62); assert.equal(final.transit, 0); assert.equal(final.stove, 0); assert.equal(final.sale_cost, 6024.38); assert.equal(final.sale_internal_cost, 48.75);
m.final_expectations = final; m.financial_extensions_started = true; persist();
}
const type = await run('electricity-type', 'save_financial_type', { p_payload: { name: 'Shared shop electricity', account: 'operating_expense', allocations: { lpg: 60, stove: 20, logistics: 20 }, is_active: true } });
const catalog = await checked(c.rpc('get_financial_catalog'));
const definition = catalog.types.find(t => t.type_id === type.type_id); assert(definition);
const expense = await run('electricity', 'record_financial_entry', { p_payload: { type_id: type.type_id, expected_revision: definition.revision, wallet_id: m.cash, amount: 600, date: today, description: 'Actual shop power bill' }, p_request_id: randomUUID() });
await run('electricity-return', 'record_financial_entry', { p_payload: { reversal_of: expense.entry_id ?? expense.id, wallet_id: m.cash, amount: 100, date: today, description: 'Supplier corrected the billed meter amount' }, p_request_id: randomUUID() });
const manager = await run('manager', 'save_employee', { p_payload: { name: 'Nadia acceptance manager', employee_type_name: 'Manager', business_unit: 'gas_business', phones: [{ phone: '01799000403', is_primary: true }], terms: { effective_from: today, monthly_salary: 16000, is_active: true } }, p_request_id: randomUUID() });
await run('salary-partial', 'employee_payment_operation', { p_payload: { action: 'pay', items: [{ employee_id: manager.employee_id, kind: 'salary', period: today.slice(0, 7) + '-01', payment_date: today, description: 'Partial current month salary', payments: [{ wallet_id: m.cash, amount: 2000 }] }] }, p_request_id: randomUUID() });
assert.equal(Number(sql(`select sum(balance) from public.wallets where tenant_id=${uuid(m.tenant_id)}`)), 964800);
m.verified_at = new Date().toISOString(); persist();
console.log(`PASS retained current-model Auth/API lab ${m.tenant_id}; ${Object.keys(m.events).length} recorded operations; wallet, journal, exchange FIFO, loan and four-scope equations reconcile`);
await c.auth.signOut();
