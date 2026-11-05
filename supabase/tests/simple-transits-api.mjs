// Real Auth/API and published UI acceptance on explicitly created disposable businesses.
import assert from 'node:assert/strict';
import { provisionTestBusiness } from './trusted-test-provisioning.mjs';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
assert(process.argv.includes('--vps'), 'Explicit --vps is required');
const frontend = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const backend = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
const secret = {
  ...parseEnv(readFileSync('.env.live-test', 'utf8')),
  ...process.env,
};
const api = 'https://api.lpg.144.79.249.4.sslip.io';
const worker = 'https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(frontend.VITE_SUPABASE_URL, api);
assert.equal(backend.VPS_HOST, '144.79.249.4');
assert.equal(backend.VPS_PROJECT_DIR, '/opt/lpg');
assert.equal(secret.LPG_TEST_EMAIL, 'sifatsiam244@gmail.com');
const ssh = [
  ...(backend.VPS_SSH_KEY ? ['-i', backend.VPS_SSH_KEY] : []),
  '-p',
  backend.VPS_PORT,
  '-o',
  'BatchMode=yes',
  '-o',
  'StrictHostKeyChecking=yes',
  `${backend.VPS_USER}@${backend.VPS_HOST}`,
];
const sql = (input) =>
  execFileSync(
    'ssh',
    [
      ...ssh,
      'sudo -n docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1',
    ],
    { input, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 },
  ).trim();
const uuid = (v) => {
  assert.match(v, /^[a-f0-9-]{36}$/i);
  return `'${v}'::uuid`;
};
const checked = async (request) => {
  const { data, error } = await request;
  if (error) throw Error(`${error.code}: ${error.message}`);
  return data;
};
const tables=sql("select c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema='public' and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by c.table_name;").split('\n');
assert(tables.every(t=>/^[a-z_]+$/.test(t)));
const preservation =
  'select jsonb_build_array(' +
  tables
    .map(
      (t) =>
        `(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from ${t === 'attendance_devices' ? '(select tenant_id,device_id,serial,name,enabled,approved_at,removed_at,created_at from public.attendance_devices)' : 'public.' + t} r)`,
    )
    .join(',') +
  ');';
let before = sql(preservation);
const clients = [],
  users = [],
  tenants = [];
const fixtureAccounts = [];
let browser;const browserErrors=[];
const client = () => {
  const c = createClient(api, frontend.VITE_SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  clients.push(c);
  return c;
};
async function account(label) {
 const c=client(); const email=`transit-${randomUUID()}@example.invalid`, password=randomUUID()+'Aa1!';
 const auth=await provisionTestBusiness(c,{email,password,businessName:'Simple transit API fixture '+label+' '+randomUUID()});
 users.push(auth.user.id);tenants.push(auth.tenant_id);fixtureAccounts.push({c,tenant:auth.tenant_id});
 return {c,user:auth.user,session:auth.session,tenant:auth.tenant_id};
}
try {
 const trusted=JSON.parse(sql("select jsonb_build_object('tenant',p.tenant_id,'active',p.is_active,'business_active',t.status='active') from auth.users u join public.user_profiles p on p.user_id=u.id join public.tenants t using(tenant_id) where u.email='sifatsiam244@gmail.com';"));
 assert(trusted.active&&trusted.business_active);
 const burner=client();await checked(burner.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));await checked(burner.rpc('get_access_context'));before=sql(preservation);
 const owner=await account('owner'),foreign=await account('foreign'),c=owner.c;
 const rpc=(name,args={})=>checked(c.rpc(name,args));
 const employee=async(name,role,phone)=>(await rpc('save_employee',{p_payload:{name,employee_type_name:role,business_unit:'truck_business',phones:[{phone,is_primary:true}],terms:{monthly_salary:0,effective_from:'2026-01-01',is_active:true}},p_request_id:randomUUID()})).employee_id;
 const d=await employee('Simple API driver','Driver','01700000951'),h=await employee('Simple API helper','Helper','01700000952');
 const v=(await rpc('save_vehicle',{p_payload:{name:'Simple API truck',serial_no:'SIMPLE-API',capacity:0,book_value:0,funding:'capital',driver_employee_id:d,helper_employee_id:h},p_request_id:randomUUID()})).vehicle_id;
 const cash=(await rpc('get_payment_wallets')).find(w=>w.type==='cash').wallet_id;
 const balance=()=>checked(c.from('wallets').select('balance').eq('wallet_id',cash).single()).then(w=>Number(w.balance));
 const category=(await rpc('get_vehicle_expense_categories')).find(c=>c.name==='Engine Oil');
 const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date());
 const service=async(title,amount)=>(await rpc('save_service_trip',{p_payload:{vehicle_id:v,title,service_date:today,expenses:[{category_id:category.category_id,amount,description:'Disposable service'}]},p_request_id:randomUUID()})).service_trip_id;
 const openService=await service('Visible open service',300),finalService=await service('Visible finalized service',200);
 await rpc('record_operating_payment',{p_payload:{service_trip_id:finalService,kind:'expense',payment_date:today,payments:[{wallet_id:cash,amount:200}]},p_request_id:randomUUID()});
 await rpc('finalize_service_trip',{p_service_trip_id:finalService,p_revision:(await rpc('get_service_trip',{p_service_trip_id:finalService})).revision,p_request_id:randomUUID()});
 assert.equal((await rpc('get_transit_directory',{p_filters:{type:'service',expense_category:'Engine Oil'}})).total,2);
 assert.equal((await rpc('get_transit_directory',{p_filters:{type:'service',status:'open'}})).entries[0].service_trip_id,openService);
 assert.equal((await checked(foreign.c.rpc('get_transit_directory',{p_filters:{vehicle_id:v}}))).total,0);
 assert((await foreign.c.rpc('get_service_trip',{p_service_trip_id:openService})).error);
 console.log('PASS live Auth/PostgREST: unified service listing, category/status filters and foreign-tenant isolation');
 browser=await chromium.launch({headless:true,channel:'chrome'});
 const context=await browser.newContext({viewport:{width:1440,height:1000}});
 await rpc('save_my_preferences',{p_theme:'light'});
 await context.addInitScript(({api,session})=>localStorage.setItem('sb-'+new URL(api).host+'-auth-token',JSON.stringify(session)),{api,session:owner.session});
 const page=await context.newPage();page.on('pageerror',e=>browserErrors.push(e.message));
 mkdirSync('.temp/simple-transits',{recursive:true});
 await page.goto(worker+'/#/logistics');await page.getByRole('button',{name:'Transits',exact:true}).click();
 const cards=page.locator('.transit-card');await cards.filter({hasText:'Visible open service'}).waitFor();
 await page.getByLabel('Journey',{exact:true}).selectOption('service');await page.getByLabel('Expense category',{exact:true}).selectOption('Engine Oil');
 await cards.filter({hasText:'Visible finalized service'}).waitFor();
 for(const theme of ['light','dark']) {
  await rpc('save_my_preferences',{p_theme:theme});await page.reload();await page.getByRole('button',{name:'Transits',exact:true}).click();await cards.filter({hasText:'Visible open service'}).waitFor();
  for(const width of [1440,390]) {
   await page.setViewportSize({width,height:1000});
   assert(await page.locator('.logistics-page').evaluate(el=>el.scrollWidth<=el.clientWidth),'Directory horizontal overflow');
   const open=await cards.filter({hasText:'Visible open service'}).locator('.service-status').evaluate(el=>({color:getComputedStyle(el).color,background:getComputedStyle(el).backgroundColor}));
   const finalized=await cards.filter({hasText:'Visible finalized service'}).locator('.service-status').evaluate(el=>({color:getComputedStyle(el).color,background:getComputedStyle(el).backgroundColor}));
   assert.notEqual(open.color,finalized.color);assert.notEqual(open.background,finalized.background);
   await page.screenshot({path:`.temp/simple-transits/services-${theme}-${width}.png`});
  }
 }
 await page.setViewportSize({width:1440,height:1000});
 await page.getByLabel('Journey',{exact:true}).selectOption('service');await page.getByLabel('Status',{exact:true}).selectOption('open');
 await cards.filter({hasText:'Visible open service'}).waitFor();assert.equal(await cards.filter({hasText:'Visible finalized service'}).count(),0);
 await cards.filter({hasText:'Visible open service'}).click();let dialog=page.getByRole('dialog',{name:'Vehicle service trip',exact:true});await dialog.getByRole('heading',{name:'Visible open service',exact:true}).waitFor();await dialog.getByRole('button',{name:'Close',exact:true}).click();
 await page.getByRole('button',{name:'Vehicles',exact:true}).click();await page.locator('.vehicle-card').filter({hasText:'Simple API truck'}).click();
 const vehicle=page.getByRole('dialog',{name:'Vehicle details',exact:true});await vehicle.getByRole('button',{name:'Service trips',exact:true}).click();await vehicle.locator('.service-open').waitFor();await vehicle.locator('.service-finalized').waitFor();
 await page.screenshot({path:'.temp/simple-transits/vehicle-statuses.png'});await vehicle.getByRole('button',{name:'Close dialog',exact:true}).click();
 await page.getByRole('button',{name:'Transits',exact:true}).click();await page.getByRole('button',{name:'Custom transit',exact:true}).click();
 dialog=page.getByRole('dialog',{name:'New custom transit',exact:true});
 await dialog.getByLabel('Client name *',{exact:true}).fill('Browser simple client');await dialog.getByLabel('Vehicle *',{exact:true}).selectOption(v);await dialog.getByLabel('Destination *',{exact:true}).fill('Dhaka');await dialog.getByLabel('Transport fee to collect (Tk)',{exact:true}).fill('5000');
 const initial=await balance();await dialog.getByRole('button',{name:'Start transit',exact:true}).click();
 const start=page.getByRole('dialog',{name:'Start this transit?',exact:true});await start.getByText('Cash Register',{exact:true}).waitFor();
 const [createdResponse]=await Promise.all([page.waitForResponse(r=>r.url().includes('/rpc/create_custom_transit')&&r.request().method()==='POST'),start.getByRole('button',{name:'Collect fee & start',exact:true}).click()]);
 const created=await createdResponse.json();assert(created.transit_id);await dialog.waitFor({state:'hidden'});assert.equal(await balance(),initial+5000);
 await page.getByLabel('Journey',{exact:true}).selectOption('all');await page.getByLabel('Status',{exact:true}).selectOption('all');
 await cards.filter({hasText:'Browser simple client'}).click();dialog=page.getByRole('dialog',{name:'Transit details',exact:true});
 assert.equal(await dialog.getByRole('button',{name:'Return vehicle Home',exact:true}).count(),0);assert.equal(await dialog.getByRole('button',{name:'Pay driver',exact:true}).count(),0);
 await dialog.getByLabel('Driver earnings (Tk)',{exact:true}).fill('100');await dialog.getByLabel('Helper earnings (Tk)',{exact:true}).fill('100');await dialog.getByLabel('Oil cost (Tk)',{exact:true}).fill('10');await dialog.getByLabel('Other costs (Tk)',{exact:true}).fill('50');
 await dialog.getByRole('button',{name:'Complete transit',exact:true}).click();
 const complete=page.getByRole('dialog',{name:'Complete this transit?',exact:true});await complete.getByRole('button',{name:'Pay & complete transit',exact:true}).waitFor();
 for(const width of [1440,390]) {await page.setViewportSize({width,height:1000});assert(await complete.evaluate(el=>el.scrollWidth<=el.clientWidth));await page.screenshot({path:`.temp/simple-transits/complete-${width}.png`});}
 await complete.getByRole('button',{name:'Pay & complete transit',exact:true}).click();await complete.waitFor({state:'hidden'});await dialog.getByText('Transit expenses are settled and locked.',{exact:true}).waitFor();
 const tr=await rpc('get_transit',{p_transit_id:created.transit_id});assert.equal(tr.total_cost,260);assert.equal(tr.driver_paid,100);assert.equal(tr.helper_paid,100);assert.equal(tr.operating_paid,60);assert.equal(tr.client_paid,5000);assert.equal(tr.outstanding,0);assert.equal(await balance(),initial+4740);assert.equal((await rpc('get_vehicle',{p_vehicle_id:v})).location,'Home');
 await rpc('transition_transit',{p_transit_id:tr.transit_id,p_action:'complete',p_revision:tr.revision-1});assert.equal(await balance(),initial+4740);
 assert.equal(sql(`select count(*) from public.wallets w where tenant_id=${uuid(owner.tenant)} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0);`),'0');
 assert.equal(browserErrors.length,0,browserErrors.join('\n'));
 console.log('PASS published browser: colored vehicle/service statuses in both themes, phone/desktop layout, full creation collection, one-step cost save/payment/completion and Home return; exact wallet reconciliation');
} catch(error) {
 console.error(String(error?.stack??error).replaceAll(secret.LPG_TEST_PASSWORD,'[redacted]').replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,'[redacted JWT]'));process.exitCode=1;
} finally {
  if (browser) await browser.close();
  for(const fixture of fixtureAccounts) {
    const pictured=await checked(fixture.c.from('items').select('item_id,image_url').not('image_url','is',null));
    for(const item of pictured)await checked(fixture.c.rpc('set_product_image',{p_item_id:item.item_id,p_image_path:null}));
    const objects=await checked(fixture.c.storage.from('product-images').list(fixture.tenant,{limit:100}));
    if(objects.length)await checked(fixture.c.storage.from('product-images').remove(objects.map(o=>`${fixture.tenant}/${o.name}`)));
    assert.equal((await checked(fixture.c.storage.from('product-images').list(fixture.tenant,{limit:100}))).length,0,'Fixture image cleanup incomplete');
  }
  if (tenants.length) {
    const ids = tenants.map(uuid).join(',');
    const cleanupTables = sql(
      "select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by c.table_schema,c.table_name;",
    ).split('\n');
    assert(cleanupTables.every((t) => /^(public|app_private)\.[a-z_]+$/.test(t)));
    sql(
      `begin;do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Simple transit API fixture %') then raise exception 'Not an accounting fixture';end if;end$$;set local session_replication_role=replica;${cleanupTables.map((t) => `delete from ${t} where tenant_id in (${ids});`).join('\n')}commit;`,
    );
  }
  if (users.length)
    sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
  for (const c of clients) await c.auth.signOut({ scope: 'local' });
  assert.equal(
    sql(preservation),
    before,
    'Original business accounting/stock fingerprints changed',
  );
  console.log(
    'PASS: only explicitly created fixtures cleaned; original businesses unchanged and burner retained',
  );
}
