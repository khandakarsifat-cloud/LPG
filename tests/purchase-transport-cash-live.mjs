// Actual Auth/PostgREST and published-browser transport settlement acceptance.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync, unlinkSync, copyFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
import { provisionTestBusiness } from '../supabase/tests/trusted-test-provisioning.mjs';

assert(process.argv.includes('--vps'));
const frontend = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const backend = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(frontend.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io');
assert.equal(backend.VPS_HOST, '144.79.249.4');
assert.equal(backend.VPS_PROJECT_DIR, '/opt/lpg');
const origin = 'https://floral-dew-443b.khandakarsifat.workers.dev';
const folder = '.temp/purchase-transport-cash';
mkdirSync(folder, { recursive: true });
const manifest = folder + '/manifest.json', credentials = folder + '/credentials.json';
let m = existsSync(manifest) ? JSON.parse(readFileSync(manifest, 'utf8')) : {
  business_name: 'Purchase cash disposable acceptance ' + randomUUID(), operations: {},
};
if (m.cleaned_at) {
  assert.match(m.tenant_id, /^[a-f0-9-]{36}$/);
  const archive = '.temp/purchase-transport-cash-history/' + m.tenant_id;
  mkdirSync(archive, { recursive: true }); copyFileSync(manifest, archive + '/manifest.json');
  m = { business_name: 'Purchase cash disposable acceptance ' + randomUUID(), operations: {} };
}
const persist = () => writeFileSync(manifest, JSON.stringify(m, null, 2));
const checked = async promise => { const { data, error } = await promise; if (error) throw Error(error.message); return data; };
const client = createClient(frontend.VITE_SUPABASE_URL, frontend.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const rpc = (name, args) => checked(client.rpc(name, args));
const ssh = [...(backend.VPS_SSH_KEY ? ['-i', backend.VPS_SSH_KEY] : []), '-p', backend.VPS_PORT,
  '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', backend.VPS_USER + '@' + backend.VPS_HOST];
const sql = input => execFileSync('ssh', [...ssh, 'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],
  { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
const uuid = value => { assert.match(value, /^[a-f0-9-]{36}$/); return "'" + value + "'::uuid"; };
if (!m.tenant_id) {
  const secret = { email: 'purchase-cash-' + randomUUID() + '@example.invalid', password: randomUUID() + 'Aa9!' };
  const fixture = await provisionTestBusiness(client, { ...secret, businessName: m.business_name, ownerName: 'Purchase cash acceptance owner' });
  Object.assign(m, { tenant_id: fixture.tenant_id, user_id: fixture.user.id });
  writeFileSync(credentials, JSON.stringify(secret)); persist();
} else await checked(client.auth.signInWithPassword(JSON.parse(readFileSync(credentials, 'utf8'))));
const context = await rpc('get_access_context');
assert.equal(context.tenant_id, m.tenant_id); assert.equal(context.business_name, m.business_name);
const run = async (key, name, args) => {
  if (m.operations[key]?.result) return m.operations[key].result;
  m.operations[key] ??= { name, args }; persist();
  const result = await rpc(name, m.operations[key].args);
  m.operations[key].result = result; persist(); return result;
};
const detail = async purchase => (await rpc('get_purchases_by_ids', { p_ids: [purchase] }))[0];
const transitFor = purchase => JSON.parse(sql('select to_jsonb(t) from public.transits t where tenant_id=' + uuid(m.tenant_id) + ' and purchase_id=' + uuid(purchase)));
let browser;
try {
  const wallets = await rpc('get_payment_wallets');
  m.cash = wallets.find(w => w.type === 'cash').wallet_id;
  await run('capital', 'move_wallet_money', { p_payload: { action: 'adjustment', wallet_id: m.cash, classification: 'capital', business: 'lpg', amount: 200000, reason: 'Purchase cash fixture funding' }, p_request_id: randomUUID() });
  m.brand = await run('brand', 'create_lpg_brand', { p_brand_name: 'Purchase cash test Gas', p_description: 'Disposable test' });
  if (typeof m.brand !== 'string') m.brand = m.brand.brand_id;
  if (!m.item) {
    m.item = (await checked(client.from('items').insert({ tenant_id: m.tenant_id, brand_id: m.brand, size_kg: 12, mouth_size: '22mm' }).select('item_id').single())).item_id; persist();
  }
  m.plant = await run('plant', 'create_gas_plant', { p_plant_name: 'Purchase cash fixture plant', p_brand_id: m.brand, p_location: 'Dhaka' });
  if (typeof m.plant !== 'string') m.plant = m.plant.plant_id;
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka' }).format(new Date());
  m.driver = (await run('driver', 'save_employee', { p_payload: { name: 'Cash fixture driver', employee_type_name: 'Driver', business_unit: 'truck_business', phones: [{ phone: '01799000701', is_primary: true }], terms: { effective_from: today, monthly_salary: 0, is_active: true } }, p_request_id: randomUUID() })).employee_id;
  m.vehicle = (await run('vehicle', 'save_vehicle', { p_payload: { name: 'Purchase cash fixture truck', serial_no: 'CASH-FIXTURE', capacity: 100, driver_employee_id: m.driver, book_value: 1000, funding: 'capital' }, p_request_id: randomUUID() })).vehicle_id;
  await run('empties', 'adjust_inventory', { p_payload: { item_id: m.item, kind: 'capital', bottle_quantity: 10, bottle_unit_cost: 1000, reason: 'Fixture owned empties' }, p_request_id: randomUUID() });
  m.purchase = (await run('draft', 'create_purchase', { p_payload: { request_id: randomUUID(), plant_id: m.plant, vehicle_id: m.vehicle, transport_cost: 500, labour_cost: 100, items: [] } })).purchase_id; persist();
  assert.equal((await detail(m.purchase)).subtotal, 0);
  if (!m.operations.products?.result) {
    await run('products', 'update_purchase', { p_purchase_id: m.purchase, p_revision: (await detail(m.purchase)).revision, p_payload: { items: [{ item_id: m.item, quantity: 10, bottle_quantity: 0, unit_price: 1000, bottle_unit_price: 0 }] } });
  }
  await run('dispatch', 'dispatch_purchase', { p_purchase_id: m.purchase, p_revision: (await detail(m.purchase)).revision });
  m.transit = transitFor(m.purchase).transit_id; persist();
  await run('advance', 'record_purchase_payment', { p_purchase_id: m.purchase, p_payments: [{ wallet_id: m.cash, amount: 1000 }], p_request_id: randomUUID() });
  await run('cancel', 'initiate_purchase_cancellation', { p_purchase_id: m.purchase, p_revision: (await detail(m.purchase)).revision, p_confirmation: 'CANCEL', p_request_id: randomUUID() });
  if (!m.browser_verified) {
    browser = await chromium.launch({ channel: 'chrome', headless: true });
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    const secret = JSON.parse(readFileSync(credentials, 'utf8'));
    await page.goto(origin + '/#/login');
    await page.getByLabel('Email Address', { exact: true }).fill(secret.email);
    await page.getByLabel('Password', { exact: true }).fill(secret.password);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForURL(url => !url.hash.includes('/login'));
    const openTransit = async () => {
      await page.goto(origin + '/?purchase-cash=' + Date.now() + '#/logistics');
      await page.getByRole('button', { name: 'Transits', exact: true }).click();
      await page.locator('.transit-card').filter({ hasText: 'Purchase cash fixture truck' }).first().click();
      await page.getByLabel('Transport refund amount (Tk)', { exact: true }).waitFor();
    };
    await openTransit();
    await page.getByLabel('Transport refund amount (Tk)', { exact: true }).fill('200');
    await page.getByRole('button', { name: 'Approve & pay transport refund', exact: true }).click();
    const rpcURL = frontend.VITE_SUPABASE_URL + '/rest/v1/rpc/refund_purchase_transport';
    const first = page.waitForResponse(r => r.url() === rpcURL);
    await page.getByRole('button', { name: 'Approve & pay refund', exact: true }).click();
    assert((await first).ok());
    await page.getByRole('heading', { name: 'Approve transport refund?', exact: true }).waitFor({ state: 'hidden' });
    await page.route(rpcURL, async route => {
      m.lost_request = route.request().postDataJSON(); persist();
      const response = await route.fetch(); assert(response.ok()); await route.abort('failed');
    }, { times: 1 });
    await page.getByLabel('Transport refund amount (Tk)', { exact: true }).fill('300');
    await page.getByRole('button', { name: 'Approve & pay transport refund', exact: true }).click();
    await page.getByRole('button', { name: 'Approve & pay refund', exact: true }).click();
    await page.getByRole('button', { name: 'Recover transport refund', exact: true }).waitFor();
    await openTransit();
    const recovery = page.waitForResponse(r => r.url() === rpcURL);
    await page.getByRole('button', { name: 'Recover transport refund', exact: true }).click();
    const recovered = await recovery; assert(recovered.ok()); assert.deepEqual(recovered.request().postDataJSON(), m.lost_request);
    assert(await page.getByRole('dialog').first().evaluate(e => e.scrollWidth <= e.clientWidth + 2));
    m.browser_verified = true; persist();
    await browser.close(); browser = undefined;
  }
  const payment = await rpc('get_purchase_transport', { p_transit_id: m.transit });
  assert.equal(payment.remaining, 0); assert.equal(payment.refunded, 500);
  const denied = await client.rpc('refund_purchase_transport', { p_transit_id: m.transit, p_amount: 1, p_request_id: randomUUID() });
  assert.match(denied.error?.message ?? '', /exceeds/);
  const settlement = await rpc('get_purchase_settlement', { p_purchase_id: m.purchase });
  await run('supplier-refund', 'refund_purchase', { p_purchase_id: m.purchase, p_obligation_id: settlement.obligations[0].obligation_id, p_payments: [{ wallet_id: m.cash, amount: 1000 }], p_request_id: randomUUID() });
  m.received_purchase = (await run('receipt-order', 'create_purchase', { p_payload: { request_id: randomUUID(), plant_id: m.plant, vehicle_id: m.vehicle, transport_cost: 500, labour_cost: 100, items: [{ item_id: m.item, quantity: 10, bottle_quantity: 0, unit_price: 1000, bottle_unit_price: 0 }] } })).purchase_id; persist();
  await run('receipt-dispatch', 'dispatch_purchase', { p_purchase_id: m.received_purchase, p_revision: (await detail(m.received_purchase)).revision });
  await run('receipt', 'receive_purchase', { p_purchase_id: m.received_purchase, p_revision: (await detail(m.received_purchase)).revision });
  const inventory = await rpc('get_product_inventory', { p_item_id: m.item });
  assert.equal((Number(inventory.valuation.gas_value)+Number(inventory.valuation.bottle_value)), 20100);
  const t = uuid(m.tenant_id);
  const totals = JSON.parse(sql(`select json_build_object(
    'physical_cash',(select sum(balance) from public.wallets where tenant_id=${t}),
    'logistics_cash',(select sum(amount) from public.accounting_lines where tenant_id=${t} and account='cash' and business_category='logistics'),
    'supplier_payable',(select sum(amount) from public.accounting_lines where tenant_id=${t} and account='supplier_payable'),
    'capital_movement',(select coalesce(sum(amount),0) from public.accounting_lines where tenant_id=${t} and account='business_allocation_equity'),
    'refund_legs',(select count(*) from public.wallet_transactions where tenant_id=${t} and type in ('purchase_transport_refund','transit_purchase_refund')),
    'unbalanced',(select count(*) from(select journal_id from public.accounting_lines where tenant_id=${t} group by journal_id having sum(amount)<>0)j));`));
  assert.deepEqual(totals, { physical_cash: 200000, logistics_cash: 500, supplier_payable: -10100, capital_movement: 0, refund_legs: 4, unbalanced: 0 });
  m.verified_at = new Date().toISOString(); m.totals = totals; persist();
  console.log('PASS live cash transport, source-linked wallet pairs, partial Logistics refunds, lost-response recovery, receipt FIFO and independent financial totals');
  await checked(client.auth.signOut({ scope: 'global' }));
  const tables = sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1").split('\n');
  assert(tables.every(v => /^(public|app_private)\.[a-z_]+$/.test(v)));
  sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id=${t} and p.user_id=${uuid(m.user_id)} and business_name like 'Purchase cash disposable acceptance %') then raise exception 'Non-fixture cleanup refused';end if;end$$;set local session_replication_role=replica;${tables.map(v => `delete from ${v} where tenant_id=${t};`).join('\n')}set local session_replication_role=origin;delete from auth.users where id=${uuid(m.user_id)};commit;`);
  m.cleaned_at = new Date().toISOString(); persist(); unlinkSync(credentials);
  console.log('PASS only the verified disposable business and generated credentials removed');
} finally { if (browser) await browser.close(); }
