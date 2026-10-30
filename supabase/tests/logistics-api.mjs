// Real Logistics Auth/API/browser acceptance. Original businesses are read-only.
// All writes use uniquely named disposable businesses, never the burner business.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright';
import { createClient } from '@supabase/supabase-js';

assert(process.argv.includes('--vps'), 'Explicit --vps target required');
const frontend = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const backend = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
const secret = { ...parseEnv(readFileSync('.env.live-test', 'utf8')), ...process.env };
const api = 'https://api.lpg.144.79.249.4.sslip.io';
const worker = 'https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(frontend.VITE_SUPABASE_URL, api); assert.equal(backend.VPS_HOST, '144.79.249.4'); assert.equal(backend.VPS_PROJECT_DIR, '/opt/lpg');
assert.equal(secret.LPG_TEST_EMAIL, 'sifatsiam244@gmail.com');
const ssh = [...(backend.VPS_SSH_KEY ? ['-i', backend.VPS_SSH_KEY] : []), '-p', backend.VPS_PORT, '-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${backend.VPS_USER}@${backend.VPS_HOST}`];
const sql = input => execFileSync('ssh', [...ssh, 'sudo -n docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }).trim();
const uuid = value => { assert.match(value, /^[a-f0-9-]{36}$/i); return `'${value}'::uuid`; };
const checked = async request => { const { data, error } = await request; if (error) throw Error(`${error.code}: ${error.message}`); return data; };
const clients = [], users = [], tenants = []; let browser;
const started = new Date().toISOString();
const tables = ['vehicles','vehicle_assignments','transits','purchase_activity','purchase_items','purchase_payments','purchase_refund_obligations','gas_plants','area_officers','items', 'inventory_movements', 'sales', 'sale_items', 'customers', 'purchases', 'wallets', 'wallet_transactions', 'employees', 'employee_terms', 'employee_payments', 'employee_activity', 'finance_requests', 'attendance_settings', 'attendance_cutoff_rules', 'attendance_devices', 'attendance_links', 'attendance_users', 'attendance_events', 'attendance_adjustments', 'attendance_device_audit', 'attendance_configuration_audit', 'business_weights'];
const snapshot = table => table === 'attendance_devices'
 ? `select tenant_id,device_id,serial,name,enabled,approved_at,removed_at,created_at from public.${table}`
 : table === 'attendance_users' ? `select tenant_id,device_id,pin,first_seen_at from public.${table} where first_seen_at<'${started}'::timestamptz`
 : table === 'attendance_events' ? `select * from public.${table} where received_at<'${started}'::timestamptz`
 : `select * from public.${table}`;
const preservation = 'select jsonb_build_array(' + tables.map(table => `(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from (${snapshot(table)}) r)`).join(',') + ');';
const before = sql(preservation);
const client = () => { const c = createClient(api, frontend.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } }); clients.push(c); return c; };
async function account(label) {
 const c = client(); const email = `logistics-${randomUUID()}@example.invalid`; const password = randomUUID() + 'Aa1!';
 const auth = await checked(c.auth.signUp({ email, password })); assert(auth.user && auth.session); users.push(auth.user.id);
 const result = await checked(c.rpc('setup_business', { p_business_name: 'Logistics API fixture ' + label, p_owner_name: 'Attendance fixture operator' }));
 tenants.push(result.tenant_id); return { c, id: auth.user.id, session: auth.session, tenant: result.tenant_id };
}
try {
 const burner = client(); const auth = await checked(burner.auth.signInWithPassword({ email: secret.LPG_TEST_EMAIL, password: secret.LPG_TEST_PASSWORD }));
 const membership = await checked(burner.from('user_profiles').select('tenant_id,is_active').eq('user_id', auth.user.id).single()); assert(membership.is_active && membership.tenant_id);
 console.log('PASS: primary VPS/Worker configuration and burner trusted membership verified read-only');
 const owner = await account('owner ' + randomUUID()), foreign = await account('foreign ' + randomUUID()); const c = owner.c;
 const rpc = (name, args = {}) => checked(c.rpc(name, args));
 const employee = async (name, role, phone) => (await rpc('save_employee', { p_payload: { name, employee_type_name: role, business_unit: 'truck_business', phones: [{ phone, is_primary: true }], terms: { monthly_salary: 15000, effective_from: '2025-01-01', is_active: true } }, p_request_id: randomUUID() })).employee_id;
 const d = await employee('API Driver One', 'Driver', '01700000201'), h = await employee('API Helper', 'Helper', '01700000202'), d2 = await employee('API Driver Two', 'Driver', '01700000203');
 const save = payload => rpc('save_vehicle', { p_payload: payload, p_request_id: randomUUID() });
 const vid = (await save({ name: 'API Vehicle', serial_no: 'API-VEHICLE', capacity: 1 })).vehicle_id;
 assert((await c.rpc('create_custom_transit', { p_payload: { vehicle_id: vid, fee: 1000, client_name: 'API client', destination: 'Dhaka' }, p_request_id: randomUUID() })).error);
 assert((await c.rpc('save_vehicle', { p_payload: { vehicle_id: vid, revision: 2, name: 'API Vehicle', serial_no: 'API-VEHICLE', capacity: 1, driver_employee_id: h }, p_request_id: randomUUID() })).error);
 await save({ ...(await rpc('get_vehicle', { p_vehicle_id: vid })), driver_employee_id: d, helper_employee_id: h });
 const body = { vehicle_id: vid, fee: 1000, client_name: 'API client', destination: 'Dhaka' }, request = randomUUID();
 const original = await rpc('create_custom_transit', { p_payload: body, p_request_id: request }); const tid = original.transit_id;
 assert.deepEqual(await rpc('create_custom_transit', { p_payload: body, p_request_id: request }), original);
 assert.equal((await rpc('get_vehicle', { p_vehicle_id: vid })).location, 'Dhaka');
 const walletRows = await checked(c.from('wallets').select('*')); const cash = walletRows.find(w => w.type === 'cash'), bank = walletRows.find(w => w.type === 'dealership'), logistics = walletRows.find(w => w.type === 'logistics');
 const balance = async () => (await checked(c.from('wallets').select('balance'))).reduce((s, w) => s + Number(w.balance), 0);
 const initialBalance = await balance();
 await rpc('save_transit_costs', { p_transit_id: tid, p_revision: 1, p_costs: { driver_cost: 500, helper_cost: 100, oil_cost: 50, others_cost: 50, additional_costs: [] } });
 assert.equal(await balance(), initialBalance);
 const today = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Dhaka' }).format(new Date());
 const pay = (employee_id, role, payments, p_request_id = randomUUID()) => rpc('employee_payment_operation', { p_payload: { action: 'pay', items: [{ employee_id, kind: 'trips', trip_count: 1, transit_id: tid, trip_role: role, payment_date: today, payments }] }, p_request_id });
 const key = randomUUID(), entries = [{ wallet_id: cash.wallet_id, amount: 100 }, { wallet_id: logistics.wallet_id, amount: 200, reference: 'API-SPLIT' }];
 const p1 = await pay(d, 'driver', entries, key); assert.deepEqual(await pay(d, 'driver', entries, key), p1);
 assert.equal((await rpc('get_transit', { p_transit_id: tid })).outstanding, 300);
 assert((await c.rpc('transition_transit', { p_transit_id: tid, p_action: 'complete', p_revision: 3 })).error);
 await rpc('transition_transit', { p_transit_id: tid, p_action: 'return', p_revision: 3 });
 await save({ ...(await rpc('get_vehicle', { p_vehicle_id: vid })), driver_employee_id: d2, helper_employee_id: null });
 assert.equal((await rpc('get_transit', { p_transit_id: tid })).driver_employee_id, d);
 await pay(d, 'driver', [{ wallet_id: bank.wallet_id, amount: 200 }]); await pay(h, 'helper', [{ wallet_id: cash.wallet_id, amount: 100 }]);
 await rpc('transition_transit', { p_transit_id: tid, p_action: 'complete', p_revision: 6 }); await rpc('transition_transit', { p_transit_id: tid, p_action: 'complete', p_revision: 6 });
 assert.equal(await balance(), initialBalance - 700);
 assert.equal((await rpc('get_logistics_summary', { p_employee_id: d })).outstanding, 0);
 assert((await rpc('get_employee_activity',{p_filters:{employee_id:d,kind:'transit'}})).total>0);
 assert((await foreign.c.rpc('get_transit', { p_transit_id: tid })).error); assert((await foreign.c.rpc('get_vehicle', { p_vehicle_id: vid })).error);
 assert.equal((await checked(foreign.c.rpc('get_vehicle_assignments', { p_filters: { vehicle_id: vid } }))).total, 0);
 await save({ ...(await rpc('get_vehicle', { p_vehicle_id: vid })), driver_employee_id: null, helper_employee_id: null });
 for (let i = 0; i < 26; i++) await save({ name: `Directory fixture ${String(i).padStart(2, '0')}`, serial_no: `DIRECTORY-${i}`, capacity: i });
 assert.equal((await rpc('get_vehicle_directory', { p_filters: { search: 'Directory fixture' }, p_offset: 25, p_limit: 25 })).entries.length, 1);
 const brand = (await rpc('create_lpg_brand', { p_brand_name: 'API Logistics Brand', p_description: '' })).brand_id;
 const plant = (await rpc('create_gas_plant', { p_plant_name: 'API Gas Plant', p_brand_id: brand, p_location: 'Dhaka' })).plant_id;
 const item = (await checked(c.from('items').insert({ tenant_id: owner.tenant, brand_id: (await rpc('create_lpg_brand', { p_brand_name: 'Purchase fixture brand', p_description: '' })).brand_id, size_kg: 12, mouth_size: '22mm' }).select('item_id').single())).item_id;
 const product = (await checked(c.from('items').select('brand_id').eq('item_id', item).single())).brand_id;
 const purchasePlant = (await rpc('create_gas_plant', { p_plant_name: 'Purchase filling plant', p_brand_id: product, p_location: 'Dhaka' })).plant_id;
 const purchaseId = (await rpc('create_purchase', { p_payload: { plant_id: purchasePlant, vehicle_id: vid, request_id: randomUUID(), transport_cost: 20, labour_cost: 0, commission: 0, items: [{ item_id: item, type: 'package', quantity: 10, unit_price: 100 }] } })).purchase_id;
 assert((await c.rpc('dispatch_purchase', { p_purchase_id: purchaseId, p_revision: 1 })).error);
 await save({ ...(await rpc('get_vehicle', { p_vehicle_id: vid })), driver_employee_id: d });
 await rpc('dispatch_purchase', { p_purchase_id: purchaseId, p_revision: 1 });
 const purchaseTransit = (await rpc('get_transit_directory', { p_filters: { vehicle_id: vid, status: 'active' } })).entries[0];
 assert.equal(purchaseTransit.destination, 'Purchase filling plant');
 await rpc('save_transit_costs', { p_transit_id: purchaseTransit.transit_id, p_revision: 1, p_costs: { driver_cost: 100, helper_cost: 0, oil_cost: 20, others_cost: 0 } });
 await rpc('receive_purchase', { p_purchase_id: purchaseId, p_revision: 2 });
 assert.equal((await rpc('get_vehicle', { p_vehicle_id: vid })).location, 'Home');
 assert.equal((await rpc('get_transit', { p_transit_id: purchaseTransit.transit_id })).status, 'returned');
 assert((await c.rpc('transition_transit', { p_transit_id: purchaseTransit.transit_id, p_action: 'complete', p_revision: 3 })).error);
 await rpc('employee_payment_operation', { p_request_id: randomUUID(), p_payload: { action: 'pay', items: [{ employee_id: d, kind: 'trips', trip_count: 1, transit_id: purchaseTransit.transit_id, trip_role: 'driver', payment_date: today, payments: [{ wallet_id: cash.wallet_id, amount: 100 }] }] } });
 await rpc('transition_transit', { p_transit_id: purchaseTransit.transit_id, p_action: 'complete', p_revision: 4 });
 assert.equal((await checked(c.from('items').select('filled_quantity').eq('item_id', item).single())).filled_quantity, 10);
 console.log('PASS: real purchase dispatch requires a Driver; receipt releases the vehicle with deferred earnings; paid completion and stock reconcile without capacity restrictions');
 console.log('PASS: real API driver/role guards, assignments, immutable crew, deferred split/partial pay, completion, pagination and tenant isolation');

 if (process.argv.includes('--browser')) {
  mkdirSync('.temp/logistics', { recursive: true }); browser = await chromium.launch({ channel: 'chrome', headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.addInitScript(({ session }) => localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token', JSON.stringify(session)), { session: owner.session });
  const page = await context.newPage(), errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.goto(worker + '/?logistics-fixture=' + randomUUID() + '#/logistics'); await page.getByRole('button', { name: 'Add vehicle', exact: true }).waitFor();
  const pagination = page.getByRole('navigation', { name: 'vehicles pages' }); await pagination.getByRole('button', { name: 'Next page' }).click(); await page.locator('.vehicle-card').first().waitFor();
  await page.getByRole('button', { name: 'Add vehicle', exact: true }).click(); const form = page.getByRole('dialog', { name: 'Add vehicle', exact: true });
  await form.getByLabel('Name *', { exact: true }).fill('UI Vehicle'); await form.getByLabel('Serial number *', { exact: true }).fill('UI-VEHICLE'); await form.getByLabel('Capacity *', { exact: true }).fill('5');
  await form.getByRole('button', { name: 'Save vehicle', exact: true }).click(); await page.getByRole('dialog',{name:'Confirm vehicle changes',exact:true}).getByRole('button',{name:'Save vehicle',exact:true}).click(); await form.waitFor({ state: 'hidden' });
  await page.getByLabel('Find a vehicle').fill('UI Vehicle'); await page.locator('.vehicle-card').filter({ hasText: 'UI Vehicle' }).click();
  const details = page.getByRole('dialog', { name: 'Vehicle details', exact: true }); await details.getByRole('button', { name: 'Edit vehicle', exact: true }).click();
  const edit = page.getByRole('dialog', { name: 'Edit vehicle', exact: true }); await edit.getByLabel('Driver', { exact: true }).selectOption(d2); await edit.getByLabel('Helper', { exact: true }).selectOption(h);
  await edit.getByRole('button', { name: 'Save vehicle', exact: true }).click();await page.getByRole('dialog',{name:'Confirm vehicle changes',exact:true}).getByRole('button',{name:'Save vehicle',exact:true}).click(); await details.waitFor(); await details.getByText('API Driver Two', { exact: true }).waitFor();
  for (const width of [1440, 768, 390]) { await page.setViewportSize({ width, height: 950 }); assert(await details.evaluate(e => e.scrollWidth <= e.clientWidth)); await page.screenshot({ path: `.temp/logistics/vehicle-${width}.png` }); }
  await details.getByRole('button', { name: 'Assignments', exact: true }).click(); await details.getByText('Current assignment', { exact: true }).first().waitFor(); await page.keyboard.press('Escape');
  await page.getByRole('button', { name: 'Transits', exact: true }).click(); await page.getByRole('button', { name: 'Custom transit', exact: true }).click();
  const custom = page.getByRole('dialog', { name: 'New custom transit', exact: true }); const uiVehicle = (await rpc('get_vehicle_directory', { p_filters: { search: 'UI-VEHICLE' } })).entries[0];
  await custom.getByLabel('Client name *', { exact: true }).fill('UI client'); await custom.getByLabel('Vehicle *', { exact: true }).selectOption(uiVehicle.vehicle_id); await custom.getByLabel('Destination *', { exact: true }).fill('Mirpur');
  await custom.getByLabel('Collected client transport fee (Tk)', { exact: true }).fill('400'); await custom.getByRole('button', { name: 'Start transit', exact: true }).click(); await custom.waitFor({ state: 'hidden' });
  await page.locator('.transit-card').filter({ hasText: 'UI client' }).click(); const transit = page.getByRole('dialog', { name: 'Transit details', exact: true });
  await transit.getByLabel('Driver earnings (Tk)', { exact: true }).fill('100'); await transit.getByLabel('Oil cost (Tk)', { exact: true }).fill('20'); await transit.getByRole('button', { name: 'Save changes', exact: true }).click();await page.getByRole('dialog',{name:'Confirm transit changes',exact:true}).getByRole('button',{name:'Save changes',exact:true}).click();
  await page.waitForResponse(r => r.url().endsWith('/rpc/get_transit') && r.ok()); assert(await transit.getByRole('button', { name: 'Complete transit', exact: true }).isDisabled());
  await transit.getByRole('button', { name: 'Pay driver', exact: true }).click(); const payment = page.getByRole('dialog', { name: 'Pay driver / helper', exact: true });
  await payment.getByLabel('Payment 1 wallet', { exact: true }).selectOption(cash.wallet_id); await payment.getByLabel('Payment 1 amount', { exact: true }).fill('40');
  await payment.getByRole('button', { name: 'Add payment', exact: true }).click(); await payment.getByLabel('Payment 2 wallet', { exact: true }).selectOption(logistics.wallet_id);
  assert.equal(await payment.getByLabel('Payment 2 amount', { exact: true }).inputValue(), '60.00');
  await page.screenshot({ path: '.temp/logistics/split-payment-phone.png' });
  await payment.getByRole('button', { name: /^Pay / }).click(); const confirmation = page.getByRole('dialog', { name: 'Confirm employee payment', exact: true }); await confirmation.getByRole('button', { name: /^Confirm payment/ }).click(); await payment.waitFor({ state: 'hidden' });
  await transit.getByRole('button', { name: 'Complete transit', exact: true }).click(); const complete = page.getByRole('dialog', { name: 'Complete this transit?', exact: true }); await complete.getByRole('button', { name: 'Confirm', exact: true }).click(); await complete.waitFor({ state: 'hidden' }); await transit.getByText('Transit expenses are settled and locked.', { exact: true }).waitFor();
  await page.keyboard.press('Escape'); await page.goto(worker + '/#/employees'); await page.getByLabel('Search employees').fill('API Driver Two'); await page.locator('.employee-card').filter({ hasText: 'API Driver Two' }).click();
  const profile = page.getByRole('dialog', { name: 'Employee profile', exact: true }); await profile.getByRole('heading',{name:'Activity history',exact:true}).waitFor(); await profile.getByLabel('Activity type').selectOption('assignment'); await page.keyboard.press('Escape');
  await page.goto(worker + '/#/settings'); await page.getByRole('button', { name: 'Gas plants', exact: true }).click(); await page.getByRole('heading', { name: 'API Gas Plant', exact: true }).waitFor();
  await page.getByRole('button', { name: 'Add gas plant', exact: true }).click(); const gas = page.getByRole('dialog', { name: 'Add gas plant', exact: true }); await gas.getByLabel('Plant name *', { exact: true }).fill('UI Gas Plant'); await gas.getByLabel('LPG brand', { exact: true }).selectOption(brand); await gas.getByRole('button', { name: 'Save plant', exact: true }).click(); await gas.waitFor({ state: 'hidden' });
  const card = page.locator('.settings-plant').filter({ hasText: 'UI Gas Plant' }); await card.getByRole('button', { name: 'Officer', exact: true }).click(); const officer = page.getByRole('dialog', { name: 'Assign area officer', exact: true }); await officer.getByLabel('Officer name *', { exact: true }).fill('UI Area Officer'); await officer.getByRole('button', { name: 'Save officer', exact: true }).click(); await officer.waitFor({ state: 'hidden' }); await card.getByText('UI Area Officer', { exact: true }).waitFor();
  assert.equal(errors.length, 0, errors.join('\n')); await context.close();
  // Read-only acceptance against the retained burner business on the new screens.
  const readContext = await browser.newContext(); await readContext.addInitScript(({ session }) => localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token', JSON.stringify(session)), { session: auth.session }); const readPage = await readContext.newPage(); await readPage.goto(worker + '/#/logistics'); await readPage.getByRole('button', { name: 'Add vehicle', exact: true }).waitFor();
  await readContext.close();
  sql(`delete from public.role_permissions where tenant_id=${uuid(foreign.tenant)}; insert into public.role_permissions select tenant_id,role_id,'gas_plants:view' from public.roles where tenant_id=${uuid(foreign.tenant)} and name='OWNER';`);
  const restricted = await browser.newContext(); await restricted.addInitScript(({ session }) => localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token', JSON.stringify(session)), { session: foreign.session }); const restrictedPage = await restricted.newPage(); await restrictedPage.goto(worker + '/#/settings'); await restrictedPage.getByRole('heading', { name: 'Gas plants', exact: true }).waitFor(); assert.equal(await restrictedPage.getByRole('button', { name: 'Add gas plant', exact: true }).count(), 0); assert.equal(await restrictedPage.getByRole('button', { name: 'Business profile', exact: true }).count(), 0); await restricted.close();
  console.log('PASS: plant-only read permission reaches Settings without exposing management controls or other settings');
  console.log('PASS: published browser vehicle creation/edit/crew, pagination, custom journey, deferred/split payment, final completion, employee integration and Settings plants/officers at desktop/tablet/phone sizes');
 }
 assert.equal(sql(`select count(*) from public.wallets w where tenant_id=${uuid(owner.tenant)} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0);`), '0');
 console.log('PASS: live fixture wallets reconcile to the sole ledger');
} catch (error) {
 if (browser) for (const context of browser.contexts()) for (const page of context.pages()) { if (!page.url().includes('login')) await page.screenshot({ path: '.temp/logistics/failure.png' }).catch(() => {}); const alerts = await page.getByRole('alert').allTextContents().catch(() => []); if (alerts.length) console.log('Browser alerts:', alerts.join(' | ')); }
 console.error(String(error?.message ?? error).replaceAll(secret.LPG_TEST_PASSWORD, '[redacted]').replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, '[redacted JWT]')); process.exitCode = 1;
} finally {
 if (browser) await browser.close();
 if (tenants.length) {
  const ids = tenants.map(uuid).join(',');
  const cleanup = ['spendings','spending_categories','wallet_transactions','employee_payment_entries','employee_payments','employee_salary_months','purchase_payments','purchase_refund_obligations','purchase_activity','inventory_movements','purchase_items','transits','purchases','vehicle_assignments','vehicles','attendance_adjustments','attendance_device_audit','attendance_configuration_audit','attendance_days','attendance_links','attendance_events','attendance_users','attendance_devices','attendance_cutoff_rules','attendance_settings','finance_requests','employee_activity','employee_terms','employee_phone_numbers','employees','employee_types','area_officers','gas_plants','items','business_weights','lpg_brands','wallets','user_roles','role_permissions','roles','audit_logs','user_profiles','tenants'];
  sql(`begin; do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Logistics API fixture %') then raise exception 'Not a Logistics fixture'; end if; end$$; set local session_replication_role=replica; ${cleanup.map(table => `delete from public.${table} where tenant_id in (${ids});`).join('\n')} commit;`);
 }
 if (users.length) sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
 for (const c of clients) await c.auth.signOut({ scope: 'local' });
 assert.equal(sql(preservation), before, 'Original business fingerprints changed');
 console.log('PASS: fixture-only cleanup; original financial, stock, operational and employee evidence unchanged; burner retained');
}
