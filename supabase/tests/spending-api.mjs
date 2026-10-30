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
const tables = ['spendings','spending_categories','vehicles','vehicle_assignments','transits','purchase_activity','purchase_items','purchase_payments','purchase_refund_obligations','gas_plants','area_officers','items', 'inventory_movements', 'sales', 'sale_items', 'customers', 'purchases', 'wallets', 'wallet_transactions', 'employees', 'employee_terms', 'employee_payments', 'employee_activity', 'finance_requests', 'attendance_settings', 'attendance_cutoff_rules', 'attendance_devices', 'attendance_links', 'attendance_users', 'attendance_events', 'attendance_adjustments', 'attendance_device_audit', 'attendance_configuration_audit', 'business_weights'];
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
 const result = await checked(c.rpc('setup_business', { p_business_name: 'Spending API fixture ' + label, p_owner_name: 'Attendance fixture operator' }));
 tenants.push(result.tenant_id); return { c, id: auth.user.id, session: auth.session, tenant: result.tenant_id };
}
try {
 const burner=client();const auth=await checked(burner.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));const member=await checked(burner.from('user_profiles').select('tenant_id,is_active').eq('user_id',auth.user.id).single());assert(member.is_active);
 const owner=await account('owner '+randomUUID()),foreign=await account('foreign '+randomUUID());const c=owner.c;const rpc=(n,a={})=>checked(c.rpc(n,a));
 let categories=await rpc('get_spending_categories');assert.equal(categories.length,4);const business=categories.find(c=>c.name==='Business'),home=categories.find(c=>c.name==='Home');const wallets=await checked(c.from('wallets').select('*'));const cash=wallets.find(w=>w.type==='cash');
 const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date());const body={category_id:business.category_id,category_name:business.name,classification:business.classification,wallet_id:cash.wallet_id,amount:125.5,spending_date:today,description:'API fixture supplies'};const id=randomUUID();const results=await Promise.all(Array.from({length:8},()=>rpc('record_spending',{p_payload:body,p_request_id:id})));assert(results.every(r=>r.spending_id===results[0].spending_id));
 await rpc('record_spending',{p_payload:{...body,category_id:home.category_id,category_name:home.name,classification:'withdrawal',amount:50,description:'API fixture Home'},p_request_id:randomUUID()});
 let history=await rpc('get_spendings');assert.equal(history.costs,125.5);assert.equal(history.withdrawals,50);assert.equal(history.total,2);
 assert.equal((await checked(c.from('wallets').select('balance').eq('wallet_id',cash.wallet_id).single())).balance,Number(cash.balance)-175.5);
 await rpc('save_spending_category',{p_payload:{...business,name:'Supplies',classification:'withdrawal'}});assert.equal((await rpc('get_spendings')).costs,125.5);
 assert((await c.rpc('record_spending',{p_payload:body,p_request_id:randomUUID()})).error);assert((await foreign.c.rpc('record_spending',{p_payload:body,p_request_id:randomUUID()})).error);assert.equal((await checked(foreign.c.rpc('get_spendings'))).total,0);
 console.log('PASS: real spending/withdrawal API, eight exact retries, category snapshots/stale guards, wallet reconciliation and tenant isolation');
 mkdirSync('.temp/spending',{recursive:true});browser=await chromium.launch({channel:'chrome',headless:true});const context=await browser.newContext({viewport:{width:1440,height:950}});await context.addInitScript(({session})=>localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token',JSON.stringify(session)),{session:owner.session});const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(worker+'/?spending-test='+randomUUID()+'#/');await page.getByRole('button',{name:'Spending / withdrawal',exact:true}).click();let dialog=page.getByRole('dialog',{name:'Spending / withdrawal',exact:true});await dialog.getByLabel('Category',{exact:true}).selectOption(home.category_id);await dialog.getByLabel('Paid from wallet',{exact:true}).selectOption(cash.wallet_id);await dialog.getByLabel('Amount (Tk)',{exact:true}).fill('25');await dialog.getByLabel('Description',{exact:true}).fill('Browser Home withdrawal');
 for(const width of [1440,768,390]){await page.setViewportSize({width,height:950});assert(await dialog.evaluate(e=>e.scrollWidth<=e.clientWidth));await page.screenshot({path:'.temp/spending/form-'+width+'.png'});}
 await dialog.getByRole('button',{name:'Review entry',exact:true}).click();let confirm=page.getByRole('dialog',{name:'Confirm spending / withdrawal',exact:true});await confirm.getByRole('button',{name:'Back',exact:true}).count();await confirm.getByRole('button',{name:'Go back',exact:true}).click();assert.equal(await dialog.getByLabel('Amount (Tk)',{exact:true}).inputValue(),'25.00');await dialog.getByRole('button',{name:'Review entry',exact:true}).click();confirm=page.getByRole('dialog',{name:'Confirm spending / withdrawal',exact:true});await confirm.getByRole('button',{name:'Record entry',exact:true}).click();await dialog.waitFor({state:'hidden'});assert.equal((await rpc('get_spendings')).withdrawals,75);
 await page.goto(worker+'/#/finance');await page.getByRole('tab',{name:'Spending & withdrawals',exact:true}).click();await page.getByText('Browser Home withdrawal',{exact:true}).waitFor();await page.getByLabel('Entry type',{exact:true}).selectOption('cost');await page.getByText('API fixture supplies',{exact:true}).waitFor();assert.equal(await page.getByText('Browser Home withdrawal',{exact:true}).count(),0);
 await page.goto(worker+'/#/settings');await page.getByRole('button',{name:'Spending categories',exact:true}).click();await page.getByRole('button',{name:'Add category',exact:true}).click();dialog=page.getByRole('dialog',{name:'Add spending category',exact:true});await dialog.getByLabel('Category name',{exact:true}).fill('Travel');await dialog.getByLabel('Classify as',{exact:true}).selectOption('cost');await dialog.getByRole('button',{name:'Save category',exact:true}).click();await dialog.waitFor({state:'hidden'});assert((await rpc('get_spending_categories')).some(c=>c.name==='Travel'));
 const employee=async(name,role,phone)=>(await rpc('save_employee',{p_payload:{name,employee_type_name:role,business_unit:'truck_business',phones:[{phone,is_primary:true}],terms:{monthly_salary:1000,effective_from:'2026-10-01',is_active:true}},p_request_id:randomUUID()})).employee_id;
 const driver=await employee('Fixture Driver','Driver','01700000701');const helper=await employee('Fixture Helper','Helper','01700000702');const staff=await employee('Fixture Staff','General Staff','01700000703');
 await page.goto(worker+'/#/logistics');await page.getByRole('button',{name:'Add vehicle',exact:true}).click();dialog=page.getByRole('dialog',{name:'Add vehicle',exact:true});await dialog.getByLabel('Name *',{exact:true}).fill('UI vehicle');await dialog.getByLabel('Serial number *',{exact:true}).fill('UI-VEHICLE');await dialog.getByLabel('Capacity *',{exact:true}).fill('100');await dialog.getByLabel('Driver',{exact:true}).selectOption(driver);await dialog.getByLabel('Helper',{exact:true}).selectOption(helper);assert.equal(await dialog.getByRole('textbox',{name:/Find/}).count(),0);assert.equal(await dialog.getByLabel('Driver',{exact:true}).locator('option').filter({hasText:'Fixture Staff'}).count(),0);await dialog.getByRole('button',{name:'Save vehicle',exact:true}).click();confirm=page.getByRole('dialog',{name:'Confirm vehicle changes',exact:true});await confirm.getByRole('button',{name:'Save vehicle',exact:true}).click();await dialog.waitFor({state:'hidden'});
 await page.goto(worker+'/#/employees');await page.getByLabel('Search employees').fill('Fixture Driver');await page.locator('.employee-card').filter({hasText:'Fixture Driver'}).click();dialog=page.getByRole('dialog',{name:'Employee profile',exact:true});await dialog.getByRole('heading',{name:'Not linked',exact:true}).waitFor();assert.equal(await dialog.getByRole('heading',{name:'Today',exact:true}).count(),0);assert.equal(errors.length,0,errors.join(' | '));
 console.log('PASS: published Dashboard spending form/confirmation, responsive widths, Finance filters, Settings category creation, role-only crew dropdowns/save confirmation and attendance heading');
 const reconciliation=sql(`select count(*) from public.wallets w where tenant_id=${uuid(owner.tenant)} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0);`);assert.equal(reconciliation,'0');
} catch (error) {
 if (browser) for (const context of browser.contexts()) for (const page of context.pages()) { if (!page.url().includes('login')) await page.screenshot({ path: '.temp/spending/failure.png' }).catch(() => {}); const alerts = await page.getByRole('alert').allTextContents().catch(() => []); if (alerts.length) console.log('Browser alerts:', alerts.join(' | ')); }
 console.error(String(error?.message ?? error).replaceAll(secret.LPG_TEST_PASSWORD, '[redacted]').replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, '[redacted JWT]')); process.exitCode = 1;
} finally {
 if (browser) await browser.close();
 if (tenants.length) {
  const ids = tenants.map(uuid).join(',');
  const cleanup = ['spendings','spending_categories','wallet_transactions','employee_payment_entries','employee_payments','employee_salary_months','purchase_payments','purchase_refund_obligations','purchase_activity','inventory_movements','purchase_items','transits','purchases','vehicle_assignments','vehicles','attendance_adjustments','attendance_device_audit','attendance_configuration_audit','attendance_days','attendance_links','attendance_events','attendance_users','attendance_devices','attendance_cutoff_rules','attendance_settings','finance_requests','employee_activity','employee_terms','employee_phone_numbers','employees','employee_types','area_officers','gas_plants','items','business_weights','lpg_brands','wallets','user_roles','role_permissions','roles','audit_logs','user_profiles','tenants'];
  sql(`begin; do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Spending API fixture %') then raise exception 'Not a Logistics fixture'; end if; end$$; set local session_replication_role=replica; ${cleanup.map(table => `delete from public.${table} where tenant_id in (${ids});`).join('\n')} commit;`);
 }
 if (users.length) sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
 for (const c of clients) await c.auth.signOut({ scope: 'local' });
 assert.equal(sql(preservation), before, 'Original business fingerprints changed');
 console.log('PASS: fixture-only cleanup; original financial, stock, operational and employee evidence unchanged; burner retained');
}
