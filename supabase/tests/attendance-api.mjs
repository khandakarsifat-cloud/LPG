// Real Auth/PostgREST/direct HTTPS ADMS and published-browser acceptance.
// All writes use uniquely named disposable businesses, never the burner business.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { createClient } from '@supabase/supabase-js';
import { provisionTestBusiness } from './trusted-test-provisioning.mjs';

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
const tables = ['items', 'inventory_movements', 'sales', 'sale_items', 'customers', 'purchases', 'wallets', 'wallet_transactions', 'employees', 'employee_terms', 'employee_payments', 'employee_activity', 'finance_requests', 'attendance_settings', 'attendance_cutoff_rules', 'attendance_devices', 'attendance_links', 'attendance_users', 'attendance_events', 'attendance_adjustments', 'attendance_device_audit', 'attendance_configuration_audit', 'business_weights'];
const snapshot = table => table === 'attendance_devices'
 ? `select tenant_id,device_id,serial,name,enabled,approved_at,removed_at,created_at from public.${table}`
 : table === 'attendance_users' ? `select tenant_id,device_id,pin,first_seen_at from public.${table} where first_seen_at<'${started}'::timestamptz`
 : table === 'attendance_events' ? `select * from public.${table} where received_at<'${started}'::timestamptz`
 : `select * from public.${table}`;
const preservation = 'select jsonb_build_array(' + tables.map(table => `(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from (${snapshot(table)}) r)`).join(',') + ');';
const before = sql(preservation);
const client = () => { const c = createClient(api, frontend.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } }); clients.push(c); return c; };
async function account(label) {
 const c = client(); const email = `attendance-${randomUUID()}@example.invalid`; const password = randomUUID() + 'Aa1!';
 const auth = await provisionTestBusiness(c,{email,password,businessName:'Attendance API fixture '+label,ownerName:'Attendance fixture operator'});assert(auth.user && auth.session);users.push(auth.user.id);
 tenants.push(auth.tenant_id); return { c, id: auth.user.id, session: auth.session, tenant: auth.tenant_id };
}
const serial = 'ATT-FIX-' + randomUUID().slice(0, 16);
const route = path => `${api}/iclock/${path}?SN=${serial}`;
async function upload(body, stamp = '1') {
 const response = await fetch(route('cdata') + '&table=ATTLOG&Stamp=' + stamp, { method: 'POST', body, signal: AbortSignal.timeout(25_000) });
 return { status: response.status, body: await response.text() };
}
const localStamp = () => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Dhaka', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(new Date());
const dateBefore = (today, days) => { const d = new Date(today + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() - days); return d.toISOString().slice(0, 10); };
try {
 const burner = client(); const auth = await checked(burner.auth.signInWithPassword({ email: secret.LPG_TEST_EMAIL, password: secret.LPG_TEST_PASSWORD }));
 const membership = await checked(burner.from('user_profiles').select('tenant_id,is_active').eq('user_id', auth.user.id).single()); assert(membership.is_active && membership.tenant_id);
 console.log('PASS: expected VPS/Worker and burner trusted membership verified read-only');
 const owner = await account('owner'); const foreign = await account('foreign'); const c = owner.c;
 const catalogs = await checked(c.rpc('get_business_catalogs')); assert.equal(catalogs.roles.length, 6); assert.equal(catalogs.weights.length, 4);
 await checked(c.rpc('save_business_catalog', { p_kind: 'role', p_id: null, p_name: 'Fixture technician', p_active: true }));
 await checked(c.rpc('save_business_catalog', { p_kind: 'weight', p_id: null, p_name: '6.5', p_active: true }));
 await checked(c.rpc('create_lpg_brand', { p_brand_name: 'Attendance fixture inventory brand', p_description: 'Disposable integration fixture' }));
 const brand = (await checked(c.rpc('list_lpg_brands', { p_active_only: false })))[0];
 await checked(c.from('items').insert({ tenant_id: owner.tenant, brand_id: brand.brand_id, size_kg: 6.5, mouth_size: '22mm' }));
 assert((await c.rpc('save_business_catalog', { p_kind: 'weight', p_id: '6.5', p_name: '6.5', p_active: true, p_remove: true })).error);
 await checked(c.rpc('save_business_catalog', { p_kind: 'weight', p_id: '6.5', p_name: '6.5', p_active: false }));
 assert((await c.from('items').insert({ tenant_id: owner.tenant, brand_id: brand.brand_id, size_kg: 6.5, mouth_size: '20mm' })).error);
 assert.equal((await checked(c.from('items').select('size_kg')))[0].size_kg, 6.5);
 await checked(c.rpc('save_business_catalog', { p_kind: 'weight', p_id: '6.5', p_name: '6.5', p_active: true }));
 const device = (await checked(c.rpc('save_attendance_device', { p_device_id: null, p_serial: serial, p_name: 'Attendance fixture MB20-VL', p_action: 'register' }))).device_id;
 let response = await fetch(route('ping')); assert.equal(response.status, 403);
 await checked(c.rpc('save_attendance_device', { p_device_id: device, p_serial: null, p_name: null, p_action: 'approve' }));
 response = await fetch(route('cdata') + '&options=all', { headers: { 'X-ADMS-Source': '203.0.113.99' } }); assert.equal(response.status, 200); assert.match(await response.text(), /GET OPTION FROM:/);
 const config = await checked(c.rpc('get_attendance_configuration')); const today = config.today, past = dateBefore(today, 2);
 assert.equal((await upload(`001\t${past} 08:00:00\t0\t1\t0`)).status, 200);
 const payload = { name: 'Attendance fixture employee', employee_type_name: 'Driver', phones: [{ phone: '01700000071', is_primary: true }], business_unit: 'gas_business', terms: { monthly_salary: 10000, effective_from: '2025-01-01', is_active: true }, attendance_links: [{ device_id: device, pin: '001', expected: null }] };
 const eid = (await checked(c.rpc('save_employee', { p_payload: payload, p_request_id: randomUUID() }))).employee_id;
 assert.equal((await checked(c.rpc('get_attendance_history', { p_employee_id: eid }))).total, 0);
 await delay(1100); const first = localStamp();
 assert.equal((await upload(`001\t${first}\t0\t1\t0\t0\t0\t0\t0\t0\t0`)).status, 200);
 await delay(1100); const last = localStamp(); const batch = `001\t${last}\t0\t1\t0`;
 const concurrent = await Promise.all([upload(batch), upload(batch), upload(batch)]); concurrent.forEach(result => assert.deepEqual(result, { status: 200, body: 'OK: 1' }));
 let history = await checked(c.rpc('get_attendance_history', { p_employee_id: eid })); assert.equal(history.total, 1); assert(history.entries[0].worked_seconds > 0);
 const activity = await checked(c.rpc('get_employee_activity', { p_filters: { employee_id: eid, kind: 'attendance' } })); assert.equal(activity.total, 2);
 for (let i = 2; i < 17; i++) {
  const day = dateBefore(today, i);
  await checked(c.rpc('correct_employee_attendance', { p_employee_id: eid, p_day: day, p_clock_in: `${day}T08:00:00`, p_clock_out: `${day}T17:00:00`, p_reason: 'Disposable live attendance fixture', p_revision: 0, p_request_id: randomUUID() }));
 }
 history = await checked(c.rpc('get_attendance_history', { p_employee_id: eid, p_offset: 12 })); assert.equal(history.entries.length, 4); assert.equal(history.total, 16);
 assert((await foreign.c.rpc('get_attendance_history', { p_employee_id: eid })).error);
 assert((await foreign.c.rpc('get_attendance_edit', { p_employee_id: eid, p_day: past })).error);
 assert((await c.from('attendance_events').select('*')).error);
 response = await fetch(`${api}/iclock/ping?SN=UNREGISTERED-FIXTURE`); assert.equal(response.status, 403);
 console.log('PASS: direct no-key/no-fixed-IP ADMS, explicit approval, real eleven-column uploads, concurrent retries, forward-only initial linking, daily activity, corrections, pagination and tenant isolation');
 if (process.argv.includes('--browser')) {
  const { chromium } = await import('playwright'); browser = await chromium.launch({ channel: 'chrome', headless: true });
  const errors = []; const context = await browser.newContext({ viewport: { width: 1440, height: 950 } });
  await context.addInitScript(({ host, session }) => localStorage.setItem(`sb-${host}-auth-token`, JSON.stringify(session)), { host: new URL(api).host, session: owner.session });
  context.setDefaultTimeout(15_000);
  const page = await context.newPage(); page.on('pageerror', error => errors.push(error.message)); mkdirSync('.temp/attendance-current', { recursive: true });
  await page.goto(worker + '/?attendance-current=1#/employees'); await page.getByRole('button', { name: 'Open Attendance fixture employee', exact: true }).click();
  await page.getByRole('button', { name: 'Attendance history', exact: true }).click();
  let dialog = page.getByRole('dialog', { name: 'Attendance history', exact: true });
  await dialog.getByRole('navigation', { name: 'attendance records pages' }).getByText('1–12 of 16 attendance records').waitFor();
  await dialog.getByRole('button', { name: 'Next page', exact: true }).click(); await dialog.getByText('13–16 of 16 attendance records', { exact: true }).waitFor();
  await dialog.getByRole('button', { name: 'Weekly', exact: true }).click(); await dialog.getByRole('columnheader', { name: 'Attended days' }).waitFor();
  await dialog.getByRole('button', { name: 'Monthly', exact: true }).click(); await dialog.getByRole('columnheader', { name: 'Month', exact: true }).waitFor();
  await dialog.getByRole('button', { name: 'Daily', exact: true }).click(); await dialog.getByRole('button', { name: 'Edit history', exact: true }).click();
  const editor = page.getByRole('dialog', { name: 'Edit attendance history', exact: true });
  await editor.getByLabel('Correction date', { exact: true }).fill(past); await editor.getByText(past + ' 08:00:00', { exact: true }).waitFor();
  await editor.getByLabel('Corrected clock out', { exact: true }).fill(`${past}T18:00`); await editor.getByLabel('Reason for correction').fill('Published browser correction fixture');
  await editor.getByRole('button', { name: 'Review changes', exact: true }).click();
  const correctionRequests = []; let loseCorrectionResponse = true;
  await page.route('**/rest/v1/rpc/correct_employee_attendance', async route => {
   correctionRequests.push(route.request().postDataJSON().p_request_id);
   const response = await route.fetch();
   if (loseCorrectionResponse) { loseCorrectionResponse = false; await route.abort('failed'); } else await route.fulfill({ response });
  });
  const confirmation = page.getByRole('dialog', { name: 'Confirm attendance correction', exact: true });
  await confirmation.getByRole('button', { name: 'Apply correction' }).click();
  await confirmation.getByRole('button', { name: 'Recover correction', exact: true }).click();
  await editor.waitFor({ state: 'hidden' });
  assert.equal(correctionRequests.length, 2); assert.equal(correctionRequests[0], correctionRequests[1]);
  await page.unroute('**/rest/v1/rpc/correct_employee_attendance');
  assert.equal((await checked(c.rpc('get_attendance_history', { p_employee_id: eid, p_from: past, p_to: past }))).entries[0].worked_seconds, 36000);
  for (const width of [1440, 812, 375, 320]) {
   await page.setViewportSize({ width, height: 950 }); await page.screenshot({ path: `.temp/attendance-current/history-${width}.png` });
   assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `Attendance overflow at ${width}`);
  }
  await dialog.getByRole('button', { name: 'Close', exact: true }).click(); await page.getByRole('dialog', { name: 'Employee profile', exact: true }).getByRole('button', { name: 'Close dialog', exact: true }).click();
  // Add Employee performs initial linking in the same save, and Edit replaces it.
  await page.getByRole('button', { name: 'Add employee', exact: true }).click();
  const form = page.getByRole('dialog', { name: 'Add employee', exact: true });
  await form.getByLabel('Employee name', { exact: true }).fill('Attendance browser created'); await form.getByLabel('Phone 1', { exact: true }).fill('01700000072');
  await form.getByRole('combobox', { name: 'Employee role', exact: true }).selectOption('Helper'); await form.getByRole('button', { name: 'Link device', exact: true }).click();
  await form.getByRole('combobox', { name: 'Attendance device', exact: true }).selectOption(device); await form.getByLabel('Machine User ID').fill('002'); await form.getByRole('button', { name: 'Link', exact: true }).click();
  await form.getByRole('button', { name: 'Add employee', exact: true }).click(); await form.waitFor({ state: 'hidden' });
  await page.getByRole('button', { name: 'Open Attendance browser created', exact: true }).click(); await page.getByRole('dialog', { name: 'Employee profile', exact: true }).getByRole('button', { name: 'Edit', exact: true }).click();
  const edit = page.getByRole('dialog', { name: 'Edit employee', exact: true }); await edit.getByRole('button', { name: 'Unlink', exact: true }).click();
  await edit.getByRole('button', { name: 'Link device', exact: true }).click(); await edit.getByRole('combobox', { name: 'Attendance device', exact: true }).selectOption(device); await edit.getByLabel('Machine User ID').fill('003'); await edit.getByRole('button', { name: 'Link', exact: true }).click();
  await edit.getByRole('button', { name: 'Save changes', exact: true }).click(); await page.getByRole('dialog', { name: 'Confirm employee changes' }).getByRole('button', { name: 'Confirm changes', exact: true }).click(); await edit.waitFor({ state: 'hidden' });
  const added = (await checked(c.rpc('get_employee_directory', { p_filters: { search: 'Attendance browser created' } }))).entries[0]; const links = (await checked(c.rpc('get_employee_attendance', { p_employee_id: added.employee_id, p_month: today }))).links;
  assert.equal(links.length, 2); assert.equal(links.find(link => !link.unlinked_at).pin, '003');
  await page.getByRole('dialog', { name: 'Employee profile', exact: true }).getByRole('button', { name: 'Close dialog', exact: true }).click();
  await page.goto(worker + '/?attendance-current=1#/settings');
  await page.getByRole('heading', { name: 'Attendance', exact: true }).waitFor(); await page.getByRole('button', { name: 'Register device', exact: true }).click(); await page.getByRole('dialog', { name: 'Register attendance device' }).getByRole('button', { name: 'Cancel', exact: true }).click();
  await page.getByRole('button', { name: 'Edit device', exact: true }).click(); const deviceForm = page.getByRole('dialog', { name: 'Edit attendance device' }); await deviceForm.getByLabel('Device name', { exact: true }).fill('Renamed fixture terminal'); await deviceForm.getByRole('button', { name: 'Save device', exact: true }).click(); await deviceForm.waitFor({ state: 'hidden' });
  for (const theme of ['light', 'dark']) {
   await checked(c.rpc('save_my_preferences', { p_theme: theme })); await page.reload();
   await page.getByRole('heading', { name: 'Attendance', exact: true }).waitFor();
   await page.waitForFunction(theme => document.documentElement.dataset.theme === theme, theme);
   for (const width of [1440, 812, 375, 320]) {
    await page.setViewportSize({ width, height: 950 });
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `Business settings overflow at ${width}`);
    await page.screenshot({ path: `.temp/attendance-current/business-${width}-${theme}.png`, fullPage: true });
   }
  }
  await page.getByLabel('Find timezone').fill('Tokyo'); assert(await page.getByRole('combobox', { name: 'Business timezone' }).locator('option').filter({ hasText: 'Tokyo' }).count());
  await page.getByRole('button', { name: 'Employee roles', exact: true }).click(); await page.getByRole('button', { name: 'Add role', exact: true }).click(); const roleForm = page.getByRole('dialog', { name: 'Add employee role' }); await roleForm.getByLabel('Role name').fill('Browser custom role'); await roleForm.getByRole('button', { name: 'Save role', exact: true }).click(); await roleForm.waitFor({ state: 'hidden' }); await page.getByText('Browser custom role', { exact: true }).waitFor();
  await page.getByRole('button', { name: 'Cylinder weights', exact: true }).click(); await page.getByRole('button', { name: 'Add weight', exact: true }).click(); const weightForm = page.getByRole('dialog', { name: 'Add weight' }); await weightForm.getByLabel('Weight (kg)', { exact: true }).fill('7.5'); await weightForm.getByRole('button', { name: 'Save weight', exact: true }).click(); await weightForm.waitFor({ state: 'hidden' }); await page.getByText('7.5 kg', { exact: true }).waitFor();
  await page.goto(worker + '/?attendance-current=1#/inventory');
  await page.getByRole('button', { name: 'Add Item', exact: false }).click();
  const itemModal = page.getByRole('dialog', { name: 'Add New Item', exact: true });
  const weightOptions = await itemModal.getByLabel('Cylinder Weight (KG) *', { exact: true }).locator('option').allTextContents();
  assert(weightOptions.includes('7.5kg') && weightOptions.includes('6.5kg'));
  await itemModal.getByRole('button', { name: 'Close dialog', exact: true }).click();
  await page.goto(worker + '/?attendance-current=1#/settings');
  await page.getByRole('button', { name: 'Appearance', exact: true }).click(); await page.getByRole('button', { name: 'Dark', exact: true }).click(); await page.getByText('Appearance saved.', { exact: true }).waitFor(); assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
  await page.reload(); await page.getByRole('button', { name: 'Appearance', exact: true }).click(); assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
  assert.equal(await page.getByRole('button', { name: 'Switch to light theme' }).count(), 0);
  for (const width of [1440, 812, 375, 320]) { await page.setViewportSize({ width, height: 950 }); await page.screenshot({ path: `.temp/attendance-current/settings-${width}-dark.png` }); assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `Settings overflow at ${width}`); }
  await page.getByRole('button', { name: 'Light', exact: true }).click(); await page.getByText('Appearance saved.', { exact: true }).waitFor();
  assert.deepEqual(errors, []); await context.close();
  // The actual burner account also loads the published app, strictly read-only.
  const burnerContext = await browser.newContext(); await burnerContext.addInitScript(({ host, session }) => localStorage.setItem(`sb-${host}-auth-token`, JSON.stringify(session)), { host: new URL(api).host, session: auth.session });
  const burnerPage = await burnerContext.newPage(); await burnerPage.goto(worker + '/?attendance-current-burner=1#/employees'); await burnerPage.getByRole('button', { name: 'Add employee', exact: true }).waitFor(); await burnerContext.close();
  console.log('PASS: published real browser attendance views/paging/correction confirmation, atomic add/link and unlink/relink, device modals, searchable timezone, role/weight management, persisted themes, 320/375/812/1440px layouts and read-only burner acceptance');
 }
 const historyBeforeRemoval = await checked(c.rpc('get_attendance_history', { p_employee_id: eid }));
 await checked(c.rpc('save_attendance_device', { p_device_id: device, p_serial: null, p_name: null, p_action: 'remove' }));
 assert.equal((await fetch(route('ping'))).status, 403);
 assert.deepEqual(await checked(c.rpc('get_attendance_history', { p_employee_id: eid })), historyBeforeRemoval);
 assert((await checked(c.rpc('get_employee_attendance', { p_employee_id: eid, p_month: today }))).links.every(link => !!link.unlinked_at));
 console.log('PASS: device removal blocks direct uploads, ends current links and preserves attendance history');
} catch (error) {
 if (browser) { for (const context of browser.contexts()) { for (const page of context.pages()) { await page.screenshot({ path: '.temp/attendance-current/failure.png' }).catch(() => {}); const alerts = await page.getByRole('alert').allTextContents().catch(() => []); if (alerts.length) console.log('Browser alerts:', alerts.join(' | ')); } } }
 console.error(String(error?.message ?? error).replaceAll(secret.LPG_TEST_PASSWORD, '[redacted]').replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, '[redacted JWT]')); process.exitCode = 1;
} finally {
 if (browser) await browser.close();
 if (tenants.length) {
  const ids = tenants.map(uuid).join(',');
  const cleanup=sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1;").split('\n');
  assert(cleanup.every(table=>/^(public|app_private)\.[a-z_]+$/.test(table)));
  sql(`begin; do $$begin if (select count(*) from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id in (${ids}) and t.business_name like 'Attendance API fixture %' and p.user_id in (${users.map(uuid).join(',')}) and p.email like 'attendance-%@example.invalid')<>${tenants.length} then raise exception 'Not an attendance fixture'; end if; end$$;set local session_replication_role=replica;${cleanup.map(table=>`delete from ${table} where tenant_id in (${ids});`).join('\n')}commit;`);
 }
 if (users.length) sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
 for (const c of clients) await c.auth.signOut({ scope: 'local' });
 assert.equal(sql(preservation), before, 'Original business fingerprints changed');
 console.log('PASS: fixture-only cleanup and unchanged original stock, financial, employee and attendance evidence; burner retained');
}
