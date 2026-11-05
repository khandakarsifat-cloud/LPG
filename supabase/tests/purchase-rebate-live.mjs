// Authenticated source operations on an explicitly owned disposable business.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync, unlinkSync, copyFileSync, readdirSync, statSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { provisionTestBusiness } from './trusted-test-provisioning.mjs';
assert(process.argv.includes('--vps'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8')), b = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(f.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io'); assert.equal(b.VPS_HOST, '144.79.249.4');
const folder = '.temp/purchase-rebate-live'; mkdirSync(folder, { recursive: true });
const file = `${folder}/manifest.json`, credentials = `${folder}/credentials.json`;
let m = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : { events: {}, business_name: `Purchase rebate disposable acceptance ${randomUUID()}` };
if (m.cleaned_at && !process.argv.includes('--cleanup') && !process.argv.includes('--verify')) {
  assert.match(m.tenant_id, /^[0-9a-f-]{36}$/);
  const archive = `.temp/purchase-rebate-history/${m.tenant_id}`; mkdirSync(archive, { recursive: true });
  for (const name of readdirSync(folder)) if (statSync(`${folder}/${name}`).isFile() && name !== 'credentials.json') copyFileSync(`${folder}/${name}`, `${archive}/${name}`);
  m = { events: {}, business_name: `Purchase rebate disposable acceptance ${randomUUID()}` };
}
assert(!m.cleaned_at, 'The requested fixture is already cleaned');
const persist = () => writeFileSync(file, JSON.stringify(m, null, 2));
const c = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const checked = async p => { const { data, error } = await p; if (error) throw Error(error.message); return data; };
const ssh = [...(b.VPS_SSH_KEY ? ['-i', b.VPS_SSH_KEY] : []), '-p', b.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${b.VPS_USER}@${b.VPS_HOST}`];
const sql = input => execFileSync('ssh', [...ssh, 'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
const uid = value => { assert.match(value, /^[0-9a-f-]{36}$/); return `'${value}'::uuid`; };
if (!m.tenant_id) {
  const secret = { email: `rebate-${randomUUID()}@example.invalid`, password: randomUUID() + 'Aa9!' };
  const fixture = await provisionTestBusiness(c, { ...secret, businessName: m.business_name, ownerName: 'Rebate acceptance owner' });
  m.tenant_id = fixture.tenant_id; m.user_id = fixture.user.id; persist(); writeFileSync(credentials, JSON.stringify(secret));
} else await checked(c.auth.signInWithPassword(JSON.parse(readFileSync(credentials, 'utf8'))));
const profile = await checked(c.rpc('get_access_context')); assert.equal(profile.tenant_id, m.tenant_id); assert.equal(profile.business_name, m.business_name);
const run = async (key, name, args) => {
  if (m.events[key]?.completed) return m.events[key].result;
  m.events[key] ??= { name, args }; persist();
  const result = await checked(c.rpc(name, m.events[key].args));
  Object.assign(m.events[key], { completed: true, result }); persist(); return result;
};
const detail = async id => (await checked(c.rpc('get_purchases_by_ids', { p_ids: [id] })))[0];
const money = (actual, expected, label) => assert.equal(Math.round(Number(actual) * 100), Math.round(expected * 100), label);
try {
  if (process.argv.includes('--cleanup')) {
    assert(m.verified_at, 'Verify the source operations before fixture cleanup');
    await c.auth.signOut({ scope: 'global' });
    const tables = sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1").split('\n');
    assert(tables.every(v => /^(public|app_private)\.[a-z_]+$/.test(v)));
    sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id=${uid(m.tenant_id)} and p.user_id=${uid(m.user_id)} and business_name like 'Purchase rebate disposable acceptance %') then raise exception 'Non-fixture cleanup refused';end if;end$$;set local session_replication_role=replica;${tables.map(v => `delete from ${v} where tenant_id=${uid(m.tenant_id)};`).join('\n')}set local session_replication_role=origin;delete from auth.users where id=${uid(m.user_id)};commit;`);
    m.cleaned_at = new Date().toISOString(); persist(); unlinkSync(credentials);
    console.log('PASS only the verified disposable rebate business/Auth identity removed; private test credentials discarded');
  } else if (process.argv.includes('--verify')) {
    assert(m.browser?.received && m.browser?.paid && m.browser?.recovered, 'Complete the published browser flows first');
    await run('selling-prices', 'save_product_prices', { p_item_id: m.item, p_customer_tier: 'retail', p_prices: { refill: { price: 1250, mrp: null }, package: { price: 5000, mrp: null } }, p_expected: { refill: null, package: null } });
    await run('sale', 'create_pos_sale', { p_customer_phone: '01799000622', p_customer_name: 'Rebate acceptance buyer', p_customer_shop_name: null, p_customer_address: 'Dhaka', p_customer_tier: 'retail', p_discount_amount: 0, p_exchange_fee: 0, p_notes: 'Historical gross COGS after rebate correction', p_items: [{ item_id: m.item, type: 'package', quantity: 1, unit_price: 5000 }], p_payments: [], p_request_id: randomUUID() });
    const types = await checked(c.rpc('get_stove_product_types'));
    m.stove = (await run('stove-product', 'save_stove_product', { p_payload: { name: 'Rebate fixture stove', type_id: types[0].type_id }, p_request_id: randomUUID() })).item_id; persist();
    const order = async (key, qty, rebate) => run(key, 'create_purchase', { p_payload: { business_category: 'stove', supplier_name: 'Rebate appliance supplier', request_id: randomUUID(), rebate_amount: rebate, items: [{ item_id: m.stove, quantity: qty, bottle_quantity: 0, unit_price: 1000, bottle_unit_price: 0 }] } });
    const original = (await order('stove-original', 3, 200)).purchase_id;
    await run('stove-original-receive', 'receive_purchase', { p_purchase_id: original, p_revision: (await detail(original)).revision });
    await run('stove-original-pay', 'record_purchase_payment', { p_purchase_id: original, p_payments: [{ wallet_id: m.cash, amount: 1000 }], p_request_id: randomUUID() });
    await run('stove-original-cancel', 'initiate_purchase_cancellation', { p_purchase_id: original, p_revision: (await detail(original)).revision, p_confirmation: 'CANCEL', p_request_id: randomUUID() });
    let settlement = await checked(c.rpc('get_purchase_settlement', { p_purchase_id: original }));
    money(settlement.company_credit, m.events['stove-next-receive']?.completed ? 0 : 200, 'Actual cancellation company credit'); money(settlement.refund_due, m.events['stove-refund']?.completed ? 0 : 1000, 'Only cash is refundable');
    await run('stove-refund', 'refund_purchase', { p_purchase_id: original, p_obligation_id: settlement.obligations[0].obligation_id, p_payments: [{ wallet_id: m.cash, amount: 1000 }], p_request_id: randomUUID() });
    const next = (await order('stove-next', 2, 300)).purchase_id;
    await run('stove-next-receive', 'receive_purchase', { p_purchase_id: next, p_revision: (await detail(next)).revision });
    await run('stove-next-pay', 'record_purchase_payment', { p_purchase_id: next, p_payments: [{ wallet_id: m.cash, amount: 1700 }], p_request_id: randomUUID() });
    settlement = await checked(c.rpc('get_purchase_settlement', { p_purchase_id: next })); money(settlement.due, 0, 'Later bill fully settled'); money(settlement.company_credit, 0, 'Credit consumed once');
    const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka' }).format(new Date()); const reports = {};
    for (const category of ['lpg', 'stove', 'logistics', 'all']) {
      reports[category] = await checked(c.rpc('get_finance_analysis', { p_filters: { from: today, to: today, grain: 'day', category } }));
      const p = reports[category].closing; money(p.assets, p.liabilities + p.equity, `${category} equation`);
    }
    const p = reports.all.closing;
    money(p.cash, 68000, 'Independent actual wallet money'); money(p.assets, 109810, 'Independent physical/financial assets'); money(p.liabilities, 0, 'Independent paid supplier position'); money(p.capital, 101000, 'Actual contributed cash and vehicle'); money(p.revenue, 11900, 'Sales plus exactly 6300 confirmed rebate income'); money(p.expenses, 3090, 'Historical external package COGS');
    const raw = JSON.parse(sql(`select json_build_object('wallets',(select sum(balance) from public.wallets where tenant_id=${uid(m.tenant_id)}),'cash',(select sum(amount) from public.accounting_lines where tenant_id=${uid(m.tenant_id)} and account='cash'),'inventory',(select filled_value from public.inventory_costs where tenant_id=${uid(m.tenant_id)} and item_id=${uid(m.item)}),'quantity',(select filled_quantity from public.items where tenant_id=${uid(m.tenant_id)} and item_id=${uid(m.item)}),'wallet_mismatches',(select count(*) from public.wallets w where tenant_id=${uid(m.tenant_id)} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)),'unbalanced',(select count(*) from(select journal_id from public.accounting_lines where tenant_id=${uid(m.tenant_id)} group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0)x));`));
    money(raw.wallets, 68000, 'Actual wallet source'); money(raw.cash, 68000, 'Canonical Cash'); money(raw.inventory, 33270, 'Gross historical LPG FIFO'); assert.equal(raw.quantity, 11); assert.equal(raw.wallet_mismatches, 0); assert.equal(raw.unbalanced, 0);
    const anon = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    assert((await anon.rpc('set_purchase_rebate', { p_purchase_id: m.purchase, p_payload: { amount: 1, revision: 1 }, p_request_id: randomUUID() })).error, 'Anonymous rebate write was allowed');
    const core = parseEnv(readFileSync('.env.core-test', 'utf8')), outsider = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    await checked(outsider.auth.signInWithPassword({ email: core.LPG_TEST_EMAIL, password: core.LPG_TEST_PASSWORD }));
    try {
      const denied = await outsider.rpc('set_purchase_rebate', { p_purchase_id: m.purchase, p_payload: { amount: 1, revision: 1 }, p_request_id: randomUUID() });
      assert.equal(denied.error?.message, 'Purchase not found', 'Foreign tenant rebate access must be denied');
    } finally { await outsider.auth.signOut({ scope: 'local' }); }
    const setRole = role => sql(`begin;delete from public.user_roles where tenant_id=${uid(m.tenant_id)} and user_id=${uid(m.user_id)};insert into public.user_roles(tenant_id,user_id,role_id) select ${uid(m.tenant_id)},${uid(m.user_id)},role_id from public.roles where tenant_id=${uid(m.tenant_id)} and name='${role}';commit;`);
    setRole('MANAGER');
    try { const denied = await c.rpc('set_purchase_rebate', { p_purchase_id: m.purchase, p_payload: { amount: 1, revision: 1 }, p_request_id: randomUUID() }); assert.equal(denied.error?.code, '42501', 'A manager cannot grant rebate income'); }
    finally { setRole('OWNER'); }
    m.verified_at = new Date().toISOString(); persist(); writeFileSync(`${folder}/verified.json`, JSON.stringify({ at: m.verified_at, raw, reports }, null, 2));
    console.log('PASS real Auth/PostgREST rebate income, actual wallet payments, cash-only refunds, company-credit reuse, historical COGS and exact independent business/consolidated positions');
  } else {
    const wallets = await checked(c.rpc('get_payment_wallets')); m.cash = wallets.find(v => v.type === 'cash').wallet_id; persist();
    await run('capital', 'move_wallet_money', { p_payload: { action: 'adjustment', wallet_id: m.cash, classification: 'capital', business: 'lpg', amount: 100000, reason: 'Original rebate fixture funds' }, p_request_id: randomUUID() });
    const brand = await run('brand', 'create_lpg_brand', { p_brand_name: 'Rebate Gas', p_description: 'Disposable rebate acceptance' }); m.brand = typeof brand === 'string' ? brand : brand.brand_id;
    if (!m.item) { m.item = (await checked(c.from('items').insert({ tenant_id: m.tenant_id, brand_id: m.brand, size_kg: 12, mouth_size: '22mm' }).select('item_id').single())).item_id; persist(); }
    const plant = await run('plant', 'create_gas_plant', { p_plant_name: 'Rebate filling plant', p_brand_id: m.brand, p_location: 'Dhaka' }); m.plant = typeof plant === 'string' ? plant : plant.plant_id;
    const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka' }).format(new Date());
    m.driver = (await run('driver', 'save_employee', { p_payload: { name: 'Rebate fixture driver', employee_type_name: 'Driver', business_unit: 'truck_business', phones: [{ phone: '01799000621', is_primary: true }], terms: { effective_from: today, monthly_salary: 0, is_active: true } }, p_request_id: randomUUID() })).employee_id;
    m.truck = (await run('truck', 'save_vehicle', { p_payload: { name: 'Rebate delivery truck', serial_no: 'REBATE-ACCEPTANCE', capacity: 100, driver_employee_id: m.driver, book_value: 1000, funding: 'capital' }, p_request_id: randomUUID() })).vehicle_id; persist();
    m.purchase = (await run('purchase', 'create_purchase', { p_payload: { request_id: randomUUID(), plant_id: m.plant, vehicle_id: m.truck, transport_cost: 600, labour_cost: 300, rebate_amount: 5000, items: [{ item_id: m.item, quantity: 10, bottle_quantity: 10, unit_price: 1000, bottle_unit_price: 2000 }] } })).purchase_id; persist();
    await run('dispatch', 'dispatch_purchase', { p_purchase_id: m.purchase, p_revision: (await detail(m.purchase)).revision });
    await run('receive', 'receive_purchase', { p_purchase_id: m.purchase, p_revision: (await detail(m.purchase)).revision });
    await run('payment', 'record_purchase_payment', { p_purchase_id: m.purchase, p_payments: [{ wallet_id: m.cash, amount: 24300 }], p_request_id: randomUUID() });
    const p = await detail(m.purchase), inventory = await checked(c.rpc('get_product_inventory', { p_item_id: m.item }));
    money(p.total_cost, 30900, 'Gross allocated acquisition cost'); money(p.paid_amount, m.browser?.['final-setup-payment']?.result ? 25300 : 24300, 'Retained actual wallet payments'); money(inventory.valuation.filled_value, 30300 + (m.browser?.received?.result ? 6000 : 0) - (m.events.sale?.completed ? 3030 : 0), 'Original operations determine historical external FIFO');
    m.initial_prices = inventory.buying_prices; m.setup_at = new Date().toISOString(); persist();
    console.log('PASS isolated real-Auth rebate fixture: gross invoice/costs, retained cash payments, noncash rebate and received historical FIFO; ready for published browser acceptance');
  }
} finally { await c.auth.signOut({ scope: 'local' }); }
