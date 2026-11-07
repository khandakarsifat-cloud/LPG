// Current canonical contract through real Auth/PostgREST; only its own fixture is removable.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync, copyFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { provisionTestBusiness } from './trusted-test-provisioning.mjs';

assert(process.argv.includes('--vps'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const b = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(f.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io');
assert.equal(b.VPS_HOST, '144.79.249.4'); assert.equal(b.VPS_PROJECT_DIR, '/opt/lpg');
const folder = '.temp/component-acceptance'; mkdirSync(folder, { recursive: true });
const file = `${folder}/manifest.json`, credentials = `${folder}/credentials.json`;
let m = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : { events: {}, business_name: `Canonical component disposable acceptance ${randomUUID()}` };
if (m.cleaned_at && !process.argv.includes('--verify') && !process.argv.includes('--cleanup')) {
  copyFileSync(file, `${folder}/completed-${m.tenant_id}.json`);
  m = { events: {}, business_name: `Canonical component disposable acceptance ${randomUUID()}` };
}
assert(!m.cleaned_at, 'Fixture already cleaned');
const persist = () => writeFileSync(file, JSON.stringify(m, null, 2));
const ssh = [...(b.VPS_SSH_KEY ? ['-i', b.VPS_SSH_KEY] : []), '-p', b.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${b.VPS_USER}@${b.VPS_HOST}`];
const sql = input => execFileSync('ssh', [...ssh, 'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
const uid = value => { assert.match(value, /^[0-9a-f-]{36}$/); return `'${value}'::uuid`; };
const checked = async promise => { const { data, error } = await promise; if (error) throw Error(`${error.code}: ${error.message}`); return data; };
const c = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const protectedAccounts = () => JSON.parse(sql(`select json_build_object('admin',(select jsonb_agg(to_jsonb(a)) from app_private.platform_superadmins a),
 'burner',(select jsonb_agg(to_jsonb(p)) from public.user_profiles p join auth.users u on u.id=p.user_id where u.email='sifatsiam244@gmail.com'));`));
if (!m.tenant_id) {
  m.protected_accounts = protectedAccounts(); persist();
  const secret = { email: `component-${randomUUID()}@example.invalid`, password: randomUUID() + 'Aa9!' };
  const fixture = await provisionTestBusiness(c, { ...secret, businessName: m.business_name, ownerName: 'Component acceptance owner' });
  m.tenant_id = fixture.tenant_id; m.user_id = fixture.user.id;
  writeFileSync(credentials, JSON.stringify(secret)); persist();
} else await checked(c.auth.signInWithPassword(JSON.parse(readFileSync(credentials, 'utf8'))));
const profile = await checked(c.rpc('get_access_context'));
assert.equal(profile.tenant_id, m.tenant_id); assert.equal(profile.business_name, m.business_name);
const run = async (key, name, args) => {
  if (m.events[key]?.completed) return m.events[key].result;
  m.events[key] ??= { name, args }; persist();
  const result = await checked(c.rpc(name, m.events[key].args));
  Object.assign(m.events[key], { completed: true, result }); persist(); return result;
};
const details = async id => (await checked(c.rpc('get_purchases_by_ids', { p_ids: [id] })))[0];
const physical = async id => checked(c.from('items').select('gas_quantity,bottle_quantity,unit_quantity').eq('item_id', id).single());
const evidence = () => JSON.parse(sql(`select json_build_object('layers',(select jsonb_agg(to_jsonb(l) order by layer_id) from app_private.fifo_layers l where tenant_id=${uid(m.tenant_id)}),
 'cost_events',(select count(*) from public.inventory_cost_entries where tenant_id=${uid(m.tenant_id)}),
 'journals',(select count(*) from public.accounting_journals where tenant_id=${uid(m.tenant_id)}));`));
try {
  if (process.argv.includes('--cleanup')) {
    assert(m.verified_at && m.browser_verified_at && m.feature_audit?.completed_at, 'Complete lifecycle, feature and browser verification first');
    await c.auth.signOut({ scope: 'global' });
    const tables = sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1").split('\n');
    assert(tables.every(v => /^(public|app_private)\.[a-z_]+$/.test(v)));
    sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id)
     where t.tenant_id=${uid(m.tenant_id)} and p.user_id=${uid(m.user_id)} and t.business_name like 'Canonical component disposable acceptance %')
     then raise exception 'Non-fixture cleanup refused';end if;end$$;set local session_replication_role=replica;
     ${tables.map(v => `delete from ${v} where tenant_id=${uid(m.tenant_id)};`).join('\n')}
     set local session_replication_role=origin;delete from auth.users where id=${uid(m.user_id)};commit;`);
    assert.deepEqual(protectedAccounts(), m.protected_accounts, 'Admin and burner memberships preserved');
    m.cleaned_at = new Date().toISOString(); persist(); unlinkSync(credentials);
    console.log('PASS only the verified component fixture removed; admin and burner preserved');
  } else if (process.argv.includes('--verify')) {
    assert(m.browser_verified_at, 'Published browser lifecycle must pass first');
    const purchase = m.browser_requests.purchase.result.purchase_id;
    const before = { gas_quantity: 4, bottle_quantity: 7, unit_quantity: 0 };
    if (!m.events['partial-refill']) assert.deepEqual(await physical(m.item), before);
    const createSale = (key, type, qty, phone, bottles = { lines: [] }) => run(key, 'create_pos_sale', {
      p_customer_phone: phone, p_customer_name: key, p_customer_shop_name: null, p_customer_address: null, p_customer_tier: 'retail',
      p_discount_amount: 0, p_exchange_fee: 0, p_notes: key, p_items: [{ item_id: m.item, type, quantity: qty, unit_price: type === 'package' ? 1400 : 900 }],
      p_payments: [], p_bottles: bottles, p_request_id: randomUUID(),
    });
    const sale = await createSale('partial-refill', 'refill', 2, '01799000733');
    await run('actual-cross-product-return', 'collect_sale_bottles', { p_sale_id: sale.sale_id, p_payload: { lines: [{ received_item_id: m.other_item, quantity: 1, acknowledged: true }], note: 'Actual product captured' }, p_request_id: randomUUID() });
    assert.deepEqual(await physical(m.item), { gas_quantity: 2, bottle_quantity: 5, unit_quantity: 0 });
    assert.deepEqual(await physical(m.other_item), { gas_quantity: 0, bottle_quantity: 1, unit_quantity: 0 });
    const bottles = await checked(c.rpc('get_sale_bottles', { p_sale_id: sale.sale_id }));
    assert.equal(bottles.expected, 2); assert.equal(bottles.outstanding, 1);
    const event = m.events['partial-refill'];
    assert.deepEqual(await checked(c.rpc(event.name, event.args)), event.result, 'Exact sale retry returns original result');
    const read = await checked(c.rpc('get_sale_receipt', { p_sale_id: sale.sale_id }));
    assert.deepEqual(read.sale.sale_items.map(v => v.type), ['refill'], 'Backend persists only the billed component agreement');
    const report = await checked(c.rpc('get_product_performance', { p_business: 'lpg' }));
    assert.equal(Number(report.totals.cogs), 2200, 'One Package 800 plus two Refill Gas 1400');
    assert.equal(Number(sql(`select sum(amount) from public.accounting_lines where tenant_id=${uid(m.tenant_id)} and account='bottle_receivable' and entity_id=${uid(sale.sale_id)};`)), 100);
    await run('cancel-refill', 'reverse_sale', { p_sale_id: sale.sale_id, p_reason: 'Exact component restoration', p_confirmation: 'CANCEL', p_request_id: randomUUID() });
    assert.deepEqual(await physical(m.item), before);
    assert.deepEqual(await physical(m.other_item), { gas_quantity: 0, bottle_quantity: 0, unit_quantity: 0 });
    await run('supplier-payment', 'record_purchase_payment', { p_purchase_id: purchase, p_payments: [{ wallet_id: m.cash, amount: 1000 }], p_request_id: randomUUID() });
    const pending = await run('cancel-order', 'create_purchase', { p_payload: { request_id: randomUUID(), plant_id: m.plant, vehicle_id: m.truck, items: [{ item_id: m.item, quantity: 2, bottle_quantity: 0, unit_price: 700, bottle_unit_price: 0 }] } });
    const prior = evidence();
    await run('cancel-order-dispatch', 'dispatch_purchase', { p_purchase_id: pending.purchase_id, p_revision: (await details(pending.purchase_id)).revision });
    assert.deepEqual(evidence(), prior, 'Dispatch is solely inventory custody');
    await run('cancel-order-release', 'initiate_purchase_cancellation', { p_purchase_id: pending.purchase_id, p_revision: (await details(pending.purchase_id)).revision, p_confirmation: 'CANCEL', p_request_id: randomUUID() });
    assert.deepEqual(evidence(), prior, 'Unreceived cancellation releases custody without FIFO or finance');
    assert.deepEqual(await physical(m.item), before);
    const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka' }).format(new Date());
    const financial = await checked(c.rpc('get_finance_analysis', { p_filters: { from: today, to: today, category: 'all' } }));
    const p = financial.closing;
    assert.equal(Number(p.assets), Number(p.liabilities) + Number(p.equity));
    assert.equal(Number(p.cash), 50400); assert.equal(Number(p.revenue), 1400); assert.equal(Number(p.expenses), 800);
    assert.equal(Number(p.capital), 51780); assert.equal(Number(p.liabilities), 2650); assert.equal(Number(p.assets), 55030);
    const reconcile = JSON.parse(sql(`select json_build_object('bad',(select count(*) from public.items where tenant_id=${uid(m.tenant_id)} and not (app_private.component_inventory_evidence(tenant_id,item_id)->>'consistent')::boolean),
      'unbalanced',(select count(*) from(select journal_id from public.accounting_lines where tenant_id=${uid(m.tenant_id)} group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0)x));`));
    assert.deepEqual(reconcile, { bad: 0, unbalanced: 0 });
    m.verified_at = new Date().toISOString(); m.verified_finance = p; persist();
    console.log('PASS real Auth/API independent component COGS, captured cross-product returns, source restoration, custody-only cancellation, exact retry and finance reconciliation');
  } else {
    m.cash = (await checked(c.rpc('get_payment_wallets'))).find(v => v.type === 'cash').wallet_id; persist();
    await run('capital', 'move_wallet_money', { p_payload: { action: 'adjustment', wallet_id: m.cash, classification: 'capital', business: 'lpg', amount: 50000, reason: 'Component fixture funds' }, p_request_id: randomUUID() });
    for (const [key, name] of [['item', 'Component Gas'], ['other_item', 'Other Component Gas']]) {
      const brand = await run(`brand-${key}`, 'create_lpg_brand', { p_brand_name: name, p_description: 'Disposable component acceptance' });
      const brandId = typeof brand === 'string' ? brand : brand.brand_id;
      if (!m[key]) { m[key] = (await checked(c.from('items').insert({ tenant_id: m.tenant_id, brand_id: brandId, size_kg: 12, mouth_size: '22mm' }).select('item_id').single())).item_id; persist(); }
      if (key === 'item') {
        const plant = await run('plant', 'create_gas_plant', { p_plant_name: 'Component plant', p_brand_id: brandId, p_location: 'Dhaka' });
        m.plant = typeof plant === 'string' ? plant : plant.plant_id; persist();
      }
    }
    for (const [key, qty, price] of [['first-bottles', 3, 100], ['second-bottles', 4, 120]])
      await run(key, 'adjust_inventory', { p_payload: { item_id: m.item, kind: 'capital', bottle_quantity: qty, bottle_unit_cost: price, reason: key }, p_request_id: randomUUID() });
    await run('selling-prices', 'save_product_prices', { p_item_id: m.item, p_customer_tier: 'retail', p_prices: { refill: { price: 900, mrp: null }, package: { price: 1400, mrp: null } }, p_expected: { refill: null, package: null } });
    await run('incoming-price', 'set_product_buying_price', { p_payload: { item_id: m.other_item, price_type: 'bottle', is_manual: true, price: 175, reason: 'Captured incoming Bottle basis', expected: null }, p_request_id: randomUUID() });
    const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka' }).format(new Date());
    m.driver = (await run('driver', 'save_employee', { p_payload: { name: 'Component driver', employee_type_name: 'Driver', business_unit: 'truck_business', phones: [{ phone: '01799000731', is_primary: true }], terms: { effective_from: today, monthly_salary: 0, is_active: true } }, p_request_id: randomUUID() })).employee_id;
    m.truck = (await run('truck', 'save_vehicle', { p_payload: { name: 'Component truck', serial_no: 'CANONICAL-COMPONENT', capacity: 100, driver_employee_id: m.driver, book_value: 1000, funding: 'capital' }, p_request_id: randomUUID() })).vehicle_id;
    if (!m.customer) {
      m.customer = (await checked(c.from('customers').insert({ tenant_id: m.tenant_id, name: 'Component browser buyer', phone: '01799000732', tier: 'retail' }).select('customer_id').single())).customer_id;
      persist();
    }
    m.before_browser = evidence(); m.setup_at = new Date().toISOString(); persist();
    console.log('PASS isolated canonical component API fixture prepared; admin and burner untouched');
  }
} finally { await c.auth.signOut({ scope: 'local' }); }
