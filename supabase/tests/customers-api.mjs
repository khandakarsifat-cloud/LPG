// Real Auth/PostgREST acceptance; only newly created fixture businesses are written.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--azure'), 'Explicit --azure target required');
const f=parseEnv(readFileSync('deploy/.env.frontend','utf8')), b=parseEnv(readFileSync('deploy/.env.backend','utf8'));
assert.equal(f.VITE_SUPABASE_URL,'https://api.lpg.20.40.48.3.sslip.io');
assert.equal(b.AZURE_PROJECT_DIR,'/opt/lpg');
const client=()=>createClient(f.VITE_SUPABASE_URL,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const sql=q=>execFileSync('ssh',['-i',b.AZURE_SSH_KEY,'-p',b.AZURE_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${b.AZURE_USER}@${b.AZURE_HOST}`,
 'cd /opt/lpg && sudo docker compose -p lpg -f compose.yml -f compose.azure.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input:q,encoding:'utf8'}).trim();
const uuid=x=>{assert.match(x,/^[0-9a-f-]{36}$/i);return `'${x}'::uuid`;};
const checked=async request=>{const {data,error}=await request;if(error)throw Error(`${error.code}: ${error.message}`);return data;};
const users=[],tenants=[],clients=[];
const preservation="select jsonb_build_object('stock',(select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i),'wallets',(select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w),'sales',(select md5(coalesce(jsonb_agg(to_jsonb(s) order by tenant_id,sale_id)::text,'')) from public.sales s),'customers',(select md5(coalesce(jsonb_agg(to_jsonb(c) order by tenant_id,customer_id)::text,'')) from public.customers c),'ledger',(select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w),'purchases',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by tenant_id,purchase_id)::text,'')) from public.purchases p));";
const before=sql(preservation);
let browser;
async function account(label){
 const c=client();clients.push(c);
 const auth=await checked(c.auth.signUp({email:`customer-filter-${label}-${randomUUID()}@example.invalid`,password:randomUUID()+'Aa1!'}));
 assert(auth.session);users.push(auth.user.id);
 const business=await checked(c.rpc('setup_business',{p_business_name:'Customer filter API fixture '+label,p_owner_name:'Fixture owner'}));
 tenants.push(business.tenant_id);return {client:c,tenant:business.tenant_id,session:auth.session};
}
try {
 const env={...parseEnv(readFileSync('.env.live-test','utf8')),...process.env};
 assert.equal(env.LPG_TEST_EMAIL,'sifatsiam244@gmail.com');
 const burner=client();clients.push(burner);
 const burnerAuth=await checked(burner.auth.signInWithPassword({email:env.LPG_TEST_EMAIL,password:env.LPG_TEST_PASSWORD}));
 const trusted=await checked(burner.from('user_profiles').select('tenant_id,is_active,tenants(business_name)').eq('user_id',burnerAuth.user.id).single());
 assert(trusted.is_active && trusted.tenant_id);await checked(burner.rpc('get_my_permissions'));
 console.log('PASS: dedicated burner Auth and trusted membership inspected read-only');
 const owner=await account('owner'),other=await account('other'),c=owner.client;
 const conflictStarted=performance.now();
 const staleOrder=await c.rpc('set_lpg_brand_order',{p_brand_ids:[],p_expected:[randomUUID()]});
 assert.equal(staleOrder.status,400);assert.equal(staleOrder.error?.code,'P0001');
 assert.match(staleOrder.error.message,/Brand order changed/);
 assert(performance.now()-conflictStarted<10000,'Stale brand order did not reject promptly');
 console.log('PASS: stale revision returns one HTTP 400/P0001 response without serialization retry');
 const records=Array.from({length:31},(_,n)=>({tenant_id:owner.tenant,customer_id:randomUUID(),name:`Filter customer ${String(n).padStart(2,'0')}`,tier:'retail',phone:'017'+String(n).padStart(8,'0'),address:'Filter fixture Dhaka'}));
 await checked(c.from('customers').insert(records));
 const products=[0,1].map(n=>({tenant_id:owner.tenant,item_id:randomUUID(),brand:'Filter fixture product '+n,size_kg:12}));
 await checked(c.from('items').insert(products));
 sql(`update public.items set filled_quantity=100,empty_quantity=100 where tenant_id=${uuid(owner.tenant)};insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from)values(${uuid(owner.tenant)},${uuid(products[0].item_id)},'retail','package',1000,now()-interval '1 day'),(${uuid(owner.tenant)},${uuid(products[1].item_id)},'retail','package',3000,now()-interval '1 day');`);
 const cash=(await checked(c.rpc('get_payment_wallets'))).find(w=>w.type==='cash');assert(cash);
 const sale=async(customer,items,paid)=>checked(c.rpc('create_pos_sale',{p_customer_id:customer.customer_id,p_customer_phone:customer.phone,p_customer_tier:'retail',p_customer_name:null,p_customer_shop_name:null,p_customer_address:null,p_discount_amount:0,p_exchange_fee:0,p_notes:'Customer filter API fixture',p_request_id:randomUUID(),p_items:items,p_payments:paid?[{wallet_id:cash.wallet_id,amount:paid}]:[]}));
 const line=(n,q)=>({item_id:products[n].item_id,type:'package',quantity:q,unit_price:n?3000:1000});
 const mixed=await sale(records[0],[line(0,2),line(1,1)],1000),small=await sale(records[1],[line(0,1)],200);
 const old=await sale(records[0],[line(0,1)],0),later=await sale(records[0],[line(1,1)],0);
 sql(`update public.sales set created_at='2026-10-02 12:00:00+06' where tenant_id=${uuid(owner.tenant)} and sale_id in (${uuid(mixed.sale_id)},${uuid(small.sale_id)});update public.sales set created_at='2026-10-01 23:59:59+06' where tenant_id=${uuid(owner.tenant)} and sale_id=${uuid(old.sale_id)};update public.sales set created_at='2026-10-03 00:00:00+06' where tenant_id=${uuid(owner.tenant)} and sale_id=${uuid(later.sale_id)};`);
 const filters={search:'filter fixture',from:'2026-10-02',to:'2026-10-02',item_ids:[products[0].item_id],transactions_min:'1',package_min:'1',sort:'sold_desc'};
 const directory=(filters,offset=0,limit=25)=>checked(c.rpc('get_customer_directory',{p_filters:filters,p_offset:offset,p_limit:limit}));
 let r=await directory(filters);assert.equal(r.total,2);assert.equal(r.entries[0].customer_id,records[0].customer_id);assert.equal(r.entries[0].total_sold_amount,5000);assert.equal(r.entries[0].total_due,4000);assert.equal(r.entries[0].package,2);assert.equal(r.entries[0].transactions,1);
 const both=await directory({...filters,item_ids:products.map(p=>p.item_id)});assert.equal(both.entries[0].total_sold_amount,5000);assert.equal(both.entries[0].package,3);assert.equal(both.entries[0].transactions,1);
 for(const sort of ['sold_asc','sold_desc','due_asc','due_desc','name_asc','name_desc','last_sale_asc','last_sale_desc']){
  const full=await directory({...filters,sort}),page0=await directory({...filters,sort},0,1),page1=await directory({...filters,sort},1,1);
  assert.deepEqual([...page0.entries,...page1.entries].map(c=>c.customer_id),full.entries.map(c=>c.customer_id));assert.equal(page1.total,2);
 }
 assert.equal((await directory({...filters,item_ids:[]})).total,0);assert.equal((await directory({...filters,transactions_min:'0',transactions_max:'0'})).total,0);
 assert.equal((await directory({},25,25)).entries.length,6);
 await checked(c.rpc('collect_sale_payment',{p_sale_id:mixed.sale_id,p_payments:[{wallet_id:cash.wallet_id,amount:100}],p_request_id:randomUUID()}));
 r=await directory(filters);assert.equal(r.entries[0].total_due,3900);assert.equal(r.entries[0].total_sold_amount,5000);
 assert.equal((await checked(other.client.rpc('get_customer_directory',{p_customer_id:records[0].customer_id}))).total,0);
 const anon=client();clients.push(anon);assert((await anon.rpc('get_customer_directory')).error);
 // Only fixture role grants change; customer-only access cannot read detailed sales.
 sql(`delete from public.role_permissions where tenant_id=${uuid(owner.tenant)} and permission_id<>'customers:view';`);
 assert.equal((await directory(filters)).total,2);assert((await c.rpc('get_customer_transactions',{p_customer_id:records[0].customer_id})).error);
 sql(`insert into public.role_permissions(tenant_id,role_id,permission_id) select r.tenant_id,r.role_id,p.permission_id from public.roles r cross join public.permissions p where r.tenant_id=${uuid(owner.tenant)} on conflict do nothing;`);
 console.log('PASS: real scoped money/dues, later payment, product OR, all sort directions, complete pagination, anonymous/foreign/capability denial');
 if(process.argv.includes('--browser-module')){
  const {pathToFileURL}=await import('node:url');const {resolve}=await import('node:path');
  const {chromium}=await import(pathToFileURL(resolve(process.argv[process.argv.indexOf('--browser-module')+1],'index.mjs')).href);
  browser=await chromium.launch({channel:'chrome',headless:true});
  const context=await browser.newContext({viewport:{width:1440,height:1000}});
  await context.addInitScript(s=>localStorage.setItem('sb-api-auth-token',JSON.stringify(s)),owner.session);
  const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto('https://floral-dew-443b.khandakarsifat.workers.dev/?customer-filter-acceptance=1#/customers');
  await page.locator('.customer-card').first().waitFor();
  await page.getByLabel('Sort by',{exact:true}).selectOption('sold');
  await page.getByRole('button',{name:'Sort direction: ascending',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.customer-grid')?.getAttribute('aria-busy')==='false');
  const dialog=page.getByRole('dialog',{name:'Advanced filters',exact:true});
  await page.getByRole('button',{name:/^Advanced filters/}).click();
  await dialog.getByLabel('From',{exact:true}).fill('2026-10-02');
  await dialog.getByLabel('To',{exact:true}).fill('2026-10-02');
  await dialog.getByLabel('Transactions minimum',{exact:true}).fill('1');
  await dialog.getByRole('button',{name:'All products',exact:false}).click();
  const picker=page.getByRole('dialog',{name:'Select products',exact:true});
  await picker.getByRole('button',{name:'Clear selection',exact:true}).click();
  await picker.getByRole('region',{name:'Filter fixture product 0 products',exact:true}).locator('.inv-tile').click();
  await picker.getByRole('button',{name:'Apply 1 product',exact:true}).click();
  await dialog.getByRole('button',{name:'Apply filters',exact:true}).click();
  await page.waitForFunction(()=>document.querySelectorAll('.customer-card').length===2&&document.querySelector('.customer-grid')?.getAttribute('aria-busy')==='false');
  assert((await page.locator('.customer-card').first().textContent()).includes('Tk 5,000.00'));
  for(const width of [320,390,768,1440]){
   await page.setViewportSize({width,height:950});
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
   mkdirSync('.temp/customer-filtering',{recursive:true});await page.screenshot({path:`.temp/customer-filtering/published-${width}.png`,fullPage:true});
  }
  assert.deepEqual(errors,[]);await context.close();console.log('PASS: published authenticated browser sorting/date/activity filters and 320/390/768/1440px layouts');
 }
} finally {
 if(browser)await browser.close();
 if(tenants.length){const ids=tenants.map(uuid).join(',');
  const tables=['finance_requests','wallet_transactions','customer_transactions','sale_payments','sale_items','sales','inventory_movements','price_books','items','customers','receipt_printers','wallets','user_roles','role_permissions','roles','audit_logs','user_profiles','tenants'];
  sql(`begin;do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Customer filter API fixture %') then raise exception 'Not a customer filter fixture';end if;end$$;create temporary table customer_fixture_cleanup(id integer);create function pg_temp.customer_fixture_cleanup() returns trigger language plpgsql as $$begin ${tables.map(t=>`delete from public.${t} where tenant_id in (${ids});`).join('\n')} return new;end$$;create trigger cleanup after insert on customer_fixture_cleanup for each row execute function pg_temp.customer_fixture_cleanup();insert into customer_fixture_cleanup values(1);commit;`);
 }
 if(users.length)sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
 for(const c of clients)await c.auth.signOut();
 assert.equal(sql(preservation),before,'Existing business data changed during acceptance');
 console.log('PASS: fixture businesses/accounts removed; existing stock, wallets, ledger, customers, sales and purchases preserved; burner retained');
}
