// Real published browser + Auth/PostgREST. Burner inspection never submits writes.
// Mutation tests use a newly provisioned disposable business, tracked and removed below.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
import { provisionTestBusiness } from '../supabase/tests/trusted-test-provisioning.mjs';

assert(process.argv.includes('--vps'),'Explicit --vps target required');
const front=parseEnv(readFileSync('deploy/.env.frontend','utf8')),back=parseEnv(readFileSync('deploy/.env.backend','utf8'));
const credentials={...parseEnv(readFileSync('.env.live-test','utf8')),...process.env};
const api='https://api.lpg.144.79.249.4.sslip.io',worker='https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(front.VITE_SUPABASE_URL,api);assert.equal(back.VPS_HOST,'144.79.249.4');assert.equal(back.VPS_PROJECT_DIR,'/opt/lpg');
assert.equal(credentials.LPG_TEST_EMAIL,'sifatsiam244@gmail.com');
const make=()=>createClient(api,front.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const burner=make(),owner=make(),anon=make(),manifest={tenant:null,user:null};
const password=randomUUID()+'Aa1!',folder='.temp/feature-audit';mkdirSync(folder,{recursive:true});
const report={checks:[],failures:[],endpoints:[],screens:[]},endpoints=new Set();
const checked=async p=>{const{data,error}=await p;if(error)throw Error(`${error.code}: ${error.message}`);return data;};
const uid=v=>{assert.match(v,/^[a-f0-9-]{36}$/i);return `'${v}'::uuid`;};
const sql=input=>execFileSync('ssh',[...(back.VPS_SSH_KEY?['-i',back.VPS_SSH_KEY]:[]),'-p',back.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${back.VPS_USER}@${back.VPS_HOST}`,
 'sudo -n docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input,encoding:'utf8',maxBuffer:4*1024*1024}).trim();
const sourceTables=['items','inventory_movements','inventory_costs','sales','sale_items','sale_payments','customers','purchases','purchase_items','wallets','wallet_transactions','financial_entries','accounting_journals','accounting_lines','employees','employee_payments'];
const originalIds=JSON.parse(sql('select json_agg(tenant_id) from public.tenants;')).map(uid).join(',');
const preservation='select jsonb_build_array('+sourceTables.map(t=>`(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from public.${t} r where tenant_id in (${originalIds}))`).join(',')+');';
const before=sql(preservation);let browser;
const pass=label=>{report.checks.push(label);console.log('PASS '+label);};
const attempt=async(label,fn)=>{try{await fn();pass(label);}catch(e){const message=String(e.message);report.failures.push({label,message});console.log('FAIL '+label+': '+message.slice(0,350));}};
const persist=()=>writeFileSync(folder+'/manifest.json',JSON.stringify(manifest,null,2));
try{
 const auth=await checked(burner.auth.signInWithPassword({email:credentials.LPG_TEST_EMAIL,password:credentials.LPG_TEST_PASSWORD}));
 const membership=await checked(burner.from('user_profiles').select('tenant_id,is_active').eq('user_id',auth.user.id).single());assert(membership.is_active);
 assert.equal((await checked(burner.rpc('get_access_context'))).tenant_id,membership.tenant_id);pass('burner trusted membership and primary VPS verified');
 browser=await chromium.launch({channel:'chrome',headless:true});
 const ctx=await browser.newContext({viewport:{width:1440,height:1000}}),page=await ctx.newPage();page.setDefaultTimeout(18000);
 page.on('pageerror',e=>report.failures.push({label:'browser runtime',message:e.message}));
 page.on('response',r=>{const u=new URL(r.url());if(u.origin===api&&u.pathname.startsWith('/rest/')){endpoints.add(r.request().method()+' '+u.pathname);if(r.status()>=400)report.failures.push({label:'HTTP '+r.status(),message:u.pathname});}});
 // Only reads are allowed while examining the existing burner account.
 await page.route(api+'/rest/v1/**',async route=>{const req=route.request(),name=new URL(req.url()).pathname.split('/').pop();if(req.method()==='POST'&&!/^(get_|list_|can_)/.test(name)){report.failures.push({label:'unexpected write',message:name});return route.abort();}await route.continue();});
 await page.goto(worker+'/?feature-audit=1#/login');
 await page.getByLabel('Email Address',{exact:true}).fill(credentials.LPG_TEST_EMAIL);await page.getByLabel('Password',{exact:true}).fill(credentials.LPG_TEST_PASSWORD);
 await page.getByRole('button',{name:'Sign In',exact:true}).click();await page.waitForURL(u=>u.hash!=='#/login');pass('published login form with real Auth');
 const settle=async()=>{await page.waitForTimeout(200);await page.waitForLoadState('networkidle');};
 const close=async()=>{for(let n=0;n<5&&await page.locator('dialog[open]').count();n++){await page.keyboard.press('Escape');await page.waitForTimeout(100);}};
 for(const route of ['','pos','sales','customers','inventory','purchases','logistics','employees','finance','settings','users','account']){
  await attempt('published route /'+route,async()=>{
   await page.goto(worker+'/?feature-audit='+route+'#/'+route);
   const roots={'':'.dashboard-page',pos:'.pos-page',sales:'.sales-page',customers:'.customers-page',inventory:'.inventory-page',purchases:'.purchases-page',logistics:'.logistics-page',employees:'.employee-page',finance:'.finance-page',settings:'.settings-workspace',users:'.access-workspace',account:'.account-screen'};
   await page.locator(roots[route]).waitFor();await settle();
   const alerts=await page.getByRole('alert').allTextContents();assert(!alerts.some(t=>/could not|unavailable|failed|error/i.test(t)),alerts.join('; '));
   const buttons=await page.getByRole('button').allTextContents();report.screens.push({route,buttons:buttons.map(t=>t.trim()).filter(Boolean)});
   if(route==='inventory'){await page.getByRole('button',{name:'Inventory History',exact:true}).click();await settle();}
   if(route==='finance')for(const label of ['Wallet ledger','Financial entries','Loans','Analysis']){await page.locator('.finance-tabs').getByRole('button',{name:label,exact:true}).click();await settle();}
   if(route==='logistics'){await page.getByRole('navigation',{name:'Logistics sections'}).getByRole('button',{name:'Transits',exact:true}).click();await settle();}
   if(route==='settings'){
    const tabs=page.locator('.settings-navigation button');for(let n=0;n<await tabs.count();n++){await tabs.nth(n).click();await settle();}
   }
   if(['sales','customers','purchases','employees'].includes(route)){
    const card=page.locator(route==='sales'?'.sale-card':route==='customers'?'.customer-card':route==='purchases'?'.purchase-card':'.employee-card').first();
    await card.waitFor();await card.click();await page.locator('dialog[open]').waitFor();await settle();
    assert(!(await page.getByRole('alert').allTextContents()).some(t=>/could not|unavailable|failed|error/i.test(t)),'Detail modal failed');await close();
   }
   for(const width of [375,320,1440]){await page.setViewportSize({width,height:900});await page.waitForTimeout(100);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),route+' page overflow at '+width);}
  });
 }
 await ctx.close();
 if(!process.argv.includes('--read-only')){
  const fixture=await provisionTestBusiness(owner,{email:`feature-audit-${randomUUID()}@example.invalid`,password,businessName:'LPG feature audit disposable '+randomUUID(),ownerName:'Feature audit owner'});
  manifest.tenant=fixture.tenant_id;manifest.user=fixture.user.id;persist();
  const rpc=async(name,args={})=>{endpoints.add('POST /rest/v1/rpc/'+name);return checked(owner.rpc(name,args));};
  const wallets=await rpc('get_payment_wallets'),cash=wallets.find(w=>w.type==='cash').wallet_id;
  const brand=await rpc('create_lpg_brand',{p_brand_name:'Feature audit LPG',p_description:'Disposable fixture'});
  const item=(await checked(owner.from('items').insert({tenant_id:manifest.tenant,brand_id:brand.brand_id,size_kg:12,mouth_size:'22mm'}).select('item_id').single())).item_id;
  await rpc('adjust_inventory',{p_payload:{item_id:item,kind:'opening',filled_quantity:30,empty_quantity:30,filled_unit_cost:1000,empty_unit_cost:500,reason:'Disposable explicitly valued stock'},p_request_id:randomUUID()});
  await rpc('save_product_prices',{p_item_id:item,p_customer_tier:'retail',p_prices:{refill:{price:700,mrp:null},package:{price:1500,mrp:null}},p_expected:{refill:null,package:null}});
  const sales=[];
  for(const [n,kind]of ['payment','bottle','both','none'].entries()){
   const args={p_customer_phone:'0177200000'+n,p_customer_name:'Audit '+kind,p_customer_shop_name:null,p_customer_address:null,p_customer_tier:'retail',p_discount_amount:0,p_exchange_fee:0,p_notes:'Disposable audit',p_items:[{item_id:item,type:'refill',quantity:1,unit_price:700},{item_id:item,type:'empty_return',quantity:1,unit_price:0}],p_customer_id:null,p_request_id:randomUUID(),p_payments:['bottle','none'].includes(kind)?[{wallet_id:cash,amount:700}]:[],p_bottles:{lines:['payment','none'].includes(kind)?[{received_item_id:item,quantity:1}]:[]}};
   const sale=await rpc('create_pos_sale',args);assert.deepEqual(await rpc('create_pos_sale',args),sale);sales.push({...sale,kind});
   const detail=await rpc('get_sale_details',{p_sale_id:sale.sale_id});assert.equal(detail.actor.full_name,'Feature audit owner');assert.equal(detail.sale_items.length,2);
  }
  pass('four money/bottle states, saved details and matching checkout retries through real API');
  for(const [dues,total]of [['all',4],['payment',2],['bottle',2],['both',1],['none',1]])assert.equal((await rpc('get_customer_directory',{p_filters:{dues}})).total,total);
  const hist=await rpc('get_inventory_history');assert(hist.entries.length);assert(hist.entries[0].actor.email.endsWith('@example.invalid'));pass('inclusive dues counts and attributed inventory history through real API');
  const both=sales.find(s=>s.kind==='both'),key=randomUUID();
  const payments={p_sale_id:both.sale_id,p_payments:[{wallet_id:cash,amount:100}],p_request_id:key};
  const results=await Promise.all(Array.from({length:4},()=>rpc('collect_sale_payment',payments)));assert(results.every(r=>JSON.stringify(r)===JSON.stringify(results[0])));
  assert.equal((await rpc('get_sale_settlement',{p_sale_id:both.sale_id})).paid,100);pass('four concurrent matching collection requests post once');
  const invalid=[['create_pos_sale',{p_customer_phone:'invalid',p_items:[]}],['get_customer_directory',{p_filters:{dues:'invalid'}}],['get_inventory_history',{p_offset:-1}],['get_inventory_history',{p_filters:{source:'invalid'}}],['collect_sale_payment',{...payments,p_request_id:randomUUID(),p_payments:[{wallet_id:cash,amount:601}]}],['collect_sale_payment',{...payments,p_payments:[{wallet_id:cash,amount:101}]}]];
  for(const[name,args]of invalid)assert((await owner.rpc(name,args)).error,'Invalid '+name+' accepted');
  assert((await burner.rpc('get_sale_details',{p_sale_id:both.sale_id})).error);assert((await anon.rpc('get_sale_details',{p_sale_id:both.sale_id})).error);pass('malformed, overpayment, changed retry, anonymous and cross-tenant reads denied');
  const testCtx=await browser.newContext({viewport:{width:1440,height:1000}});
  await testCtx.addInitScript(s=>localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token',JSON.stringify(s)),fixture.session);
  const p=await testCtx.newPage();p.setDefaultTimeout(20000);
  await p.goto(worker+'/?feature-fixture=1#/customers');await p.locator('.customer-card').first().waitFor();
  for(const[dues,count]of [['payment',2],['bottle',2],['both',1],['none',1],['all',4]]){
   await p.getByLabel('Dues',{exact:true}).selectOption(dues);
   await p.waitForFunction(count=>document.querySelectorAll('.customer-card').length===count&&document.querySelector('.customer-grid')?.getAttribute('aria-busy')==='false',count);
  }
  pass('published browser selects all five dues filters with independent expected counts');
  await p.goto(worker+'/?feature-fixture=1#/sales');await p.locator('.sale-card').first().click();
  const detail=p.locator('dialog.transaction-detail-dialog');await detail.getByText('Feature audit owner',{exact:true}).waitFor();
  await detail.getByRole('button',{name:'Print receipt',exact:true}).click();await p.getByRole('heading',{name:/receipt/i}).last().waitFor();
  await p.keyboard.press('Escape');await p.keyboard.press('Escape');pass('published transaction modal and receipt preview load');
  for(const route of ['pos','inventory','purchases','employees','finance','logistics','settings','users']){
   await p.goto(worker+'/?feature-fixture=1#/'+route);await p.waitForLoadState('networkidle');
   report.screens.push({fixture:true,route,buttons:(await p.getByRole('button').allTextContents()).map(t=>t.trim()).filter(Boolean)});
  }
  await p.goto(worker+'/?feature-fixture=1#/inventory');await p.getByRole('button',{name:'Inventory History',exact:true}).click();await p.getByText(/by feature-audit-/).first().waitFor();pass('published inventory history loads movement attribution');
  await testCtx.close();
  assert.equal(sql(`select count(*) from(select journal_id from public.accounting_lines where tenant_id=${uid(manifest.tenant)} group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0)x;`),'0');
  assert.equal(sql(`select count(*) from public.wallets w where tenant_id=${uid(manifest.tenant)} and balance<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=w.tenant_id and l.account='cash' and l.entity_id=w.wallet_id),0);`),'0');
  pass('fixture journals balance and wallet totals agree with independent journal recomputation');
 }
}catch(e){report.failures.push({label:'audit',message:String(e.stack??e).replaceAll(password,'[redacted]').replaceAll(credentials.LPG_TEST_PASSWORD,'[redacted]').replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g,'[redacted token]')});console.log('FAIL audit: '+String(e.message).slice(0,350));}
finally{
 if(browser)await browser.close();await owner.auth.signOut({scope:'global'});await burner.auth.signOut({scope:'local'});
 if(manifest.tenant){
  const tables=sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1;").split('\n');assert(tables.every(t=>/^(public|app_private)\.[a-z_]+$/.test(t)));
  sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id=${uid(manifest.tenant)} and p.user_id=${uid(manifest.user)} and t.business_name like 'LPG feature audit disposable %') then raise exception 'Refusing non-fixture cleanup';end if;end$$;set local session_replication_role=replica;${tables.map(t=>`delete from ${t} where tenant_id=${uid(manifest.tenant)};`).join('\n')}commit;`);
 }
 if(manifest.user)sql(`delete from auth.users where id=${uid(manifest.user)};`);
 assert.equal(sql(preservation),before,'Existing business sources changed during audit');pass('fixture-only cleanup and existing stock, finances and business source fingerprints preserved');
 report.endpoints=[...endpoints].sort();writeFileSync(folder+'/report.json',JSON.stringify(report,null,2));
 console.log(`AUDIT ${report.checks.length} checks; ${report.failures.length} failures; ${report.endpoints.length} observed endpoints. Report ${folder}/report.json`);
 if(report.failures.length)process.exitCode=1;
}
