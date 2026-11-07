// Actual Auth/PostgREST + published UI acceptance, in an owned disposable tenant.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync, unlinkSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright';
import { createClient } from '@supabase/supabase-js';
import { provisionTestBusiness } from '../supabase/tests/trusted-test-provisioning.mjs';

assert(process.argv.includes('--vps'));
const frontend=parseEnv(readFileSync('deploy/.env.frontend','utf8'));
const backend=parseEnv(readFileSync('deploy/.env.backend','utf8'));
const api='https://api.lpg.144.79.249.4.sslip.io';
const site=process.env.LPG_BROWSER_BASE ?? 'https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(frontend.VITE_SUPABASE_URL,api);assert.equal(backend.VPS_HOST,'144.79.249.4');assert.equal(backend.VPS_PROJECT_DIR,'/opt/lpg');
const root='.temp/summarized-actions-live';mkdirSync(root,{recursive:true});
const pointer=`${root}/current.json`;
let runId=!process.argv.includes('--new-run')&&existsSync(pointer)?JSON.parse(readFileSync(pointer,'utf8')).id:randomUUID();
if(existsSync(`${root}/${runId}/manifest.json`)&&JSON.parse(readFileSync(`${root}/${runId}/manifest.json`,'utf8')).cleaned_at)runId=randomUUID();
assert.match(runId,/^[a-f0-9-]{36}$/);
const folder=`${root}/${runId}`;mkdirSync(folder,{recursive:true});writeFileSync(pointer,JSON.stringify({id:runId}));
const manifest=`${folder}/manifest.json`,credentials=`${folder}/credentials.json`;
const m=existsSync(manifest)?JSON.parse(readFileSync(manifest,'utf8')):{name:`Summarized accounting disposable acceptance ${runId}`,events:{}};
const secret=existsSync(credentials)?JSON.parse(readFileSync(credentials,'utf8')):{email:`event-${runId}@example.invalid`,password:randomUUID()+'Aa9!'};
writeFileSync(credentials,JSON.stringify(secret));
const persist=()=>writeFileSync(manifest,JSON.stringify(m,null,2));
const c=createClient(api,frontend.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async request=>{const {data,error}=await request;if(error)throw Error(error.message);return data;};
const ssh=[...(backend.VPS_SSH_KEY?['-i',backend.VPS_SSH_KEY]:[]),'-p',backend.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${backend.VPS_USER}@${backend.VPS_HOST}`];
const sql=query=>execFileSync('ssh',[...ssh,'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input:query,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
const uid=id=>{assert.match(id,/^[a-f0-9-]{36}$/);return `'${id}'::uuid`;};
const headers=()=>Number(sql(`select count(*) from public.accounting_journals where tenant_id=${uid(m.tenant_id)};`));
const run=async(key,rpc,args,expected)=>{
 if(m.events[key]?.result!==undefined)return m.events[key].result;
 m.events[key]??={rpc,args,before:headers()};persist();
 const event=m.events[key];const data=await checked(c.rpc(event.rpc,event.args));
 assert.equal(headers()-event.before,expected,`${key}: financial action header count`);
 event.result=data;persist();return data;
};
const preservation=()=>sql(`select md5(jsonb_build_array((select coalesce(jsonb_agg(to_jsonb(j) order by tenant_id,journal_id),'[]') from public.accounting_journals j where tenant_id<>${uid(m.tenant_id)}),(select coalesce(jsonb_agg(to_jsonb(l) order by tenant_id,journal_id,line_no),'[]') from public.accounting_lines l where tenant_id<>${uid(m.tenant_id)}),(select coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id),'[]') from public.wallet_transactions w where tenant_id<>${uid(m.tenant_id)}),(select coalesce(jsonb_agg(to_jsonb(f) order by tenant_id,layer_id),'[]') from app_private.fifo_layers f where tenant_id<>${uid(m.tenant_id)}))::text);`);
const today=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dhaka'}).format(new Date());
let browser;
try{
 if(!m.tenant_id){const fixture=await provisionTestBusiness(c,{...secret,businessName:m.name});m.tenant_id=fixture.tenant_id;m.user_id=fixture.user.id;persist();}
 else await checked(c.auth.signInWithPassword(secret));
 assert.equal((await checked(c.rpc('get_access_context'))).tenant_id,m.tenant_id);
 m.before_preservation??=preservation();persist();
 const wallets=await checked(c.rpc('get_payment_wallets'));
 m.cash=wallets.find(w=>w.type==='cash').wallet_id;m.bank=wallets.find(w=>w.type==='dealership').wallet_id;persist();
 await run('capital','accounting_operation',{p_payload:{action:'capital',amount:10000,wallet_id:m.cash,date:today,description:'Fixture capital'},p_request_id:randomUUID()},1);
 const brand=await run('brand','create_lpg_brand',{p_brand_name:'Compact company',p_description:'Disposable fixture'},0);m.brand=typeof brand==='string'?brand:brand.brand_id;
 const other=await run('other-brand','create_lpg_brand',{p_brand_name:'Actual return company',p_description:'Disposable fixture'},0);m.other_brand=typeof other==='string'?other:other.brand_id;persist();
 for(const [key,brandId] of [['item',m.brand],['other_item',m.other_brand]])if(!m[key]){m[key]=(await checked(c.from('items').insert({tenant_id:m.tenant_id,brand_id:brandId,size_kg:12,mouth_size:'22mm'}).select('item_id').single())).item_id;persist();}
 await run('other-price','set_product_buying_price',{p_payload:{item_id:m.other_item,price_type:'bottle',price:1900,is_manual:true,expected:null,reason:'Actual returned bottle reference'},p_request_id:randomUUID()},0);
 await run('owned-bottles','adjust_inventory',{p_payload:{item_id:m.item,kind:'capital',bottle_quantity:3,bottle_unit_cost:1200,reason:'Original owned shells'},p_request_id:randomUUID()},1);
 const plant=await run('plant','create_gas_plant',{p_plant_name:'Compact fixture plant',p_brand_id:m.brand,p_location:'Dhaka'},0);m.plant=typeof plant==='string'?plant:plant.plant_id;
 m.driver=(await run('driver','save_employee',{p_payload:{name:'Compact fixture driver',employee_type_name:'Driver',business_unit:'truck_business',phones:[{phone:'01799000666',is_primary:true}],terms:{effective_from:today,monthly_salary:0,is_active:true}},p_request_id:randomUUID()},0)).employee_id;
 m.truck=(await run('truck','save_vehicle',{p_payload:{name:'Compact fixture truck',serial_no:'COMPACT-EVENT',capacity:100,driver_employee_id:m.driver,book_value:100000,funding:'capital'},p_request_id:randomUUID()},1)).vehicle_id;persist();
 m.purchase=(await run('purchase','create_purchase',{p_payload:{request_id:randomUUID(),plant_id:m.plant,vehicle_id:m.truck,transport_cost:100,labour_cost:50,items:[{item_id:m.item,quantity:4,bottle_quantity:1,unit_price:800,bottle_unit_price:1600}]}},0)).purchase_id;persist();
 const purchase=async()=>(await checked(c.rpc('get_purchases_by_ids',{p_ids:[m.purchase]})))[0];
 await run('dispatch','dispatch_purchase',{p_purchase_id:m.purchase,p_revision:(await purchase()).revision},1);
 await run('receipt','receive_purchase',{p_purchase_id:m.purchase,p_revision:(await purchase()).revision},1);
 await run('supplier-payment','record_purchase_payment',{p_purchase_id:m.purchase,p_payments:[{wallet_id:m.cash,amount:1000},{wallet_id:m.bank,amount:1000}],p_request_id:randomUUID()},1);
 if(!m.price_setup){sql(`insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price) values(${uid(m.tenant_id)},${uid(m.item)},'retail','refill',1250),(${uid(m.tenant_id)},${uid(m.item)},'retail','package',3000);`);m.price_setup=true;persist();}
 const saleArgs={p_customer_phone:'01799000555',p_customer_name:'Compact buyer',p_customer_shop_name:null,p_customer_address:null,p_customer_tier:'retail',p_discount_amount:0,p_exchange_fee:0,p_notes:'Compact checkout fixture',p_items:[{item_id:m.item,type:'refill',quantity:1,unit_price:1250},{item_id:m.item,type:'package',quantity:1,unit_price:3000}],p_request_id:randomUUID(),p_payments:[{wallet_id:m.cash,amount:1000},{wallet_id:m.bank,amount:1000}],p_bottles:{lines:[],note:'Return later'}};
 m.sale=(await run('checkout','create_pos_sale',saleArgs,1)).sale_id;persist();
 const count=headers();await checked(c.rpc('create_pos_sale',m.events.checkout.args));assert.equal(headers(),count,'Exact checkout retry');
 await run('partial','collect_sale_payment',{p_sale_id:m.sale,p_payments:[{wallet_id:m.bank,amount:500}],p_request_id:randomUUID()},1);
 await run('bottles','collect_sale_bottles',{p_sale_id:m.sale,p_payload:{lines:[{received_item_id:m.other_item,quantity:1,acknowledged:true}],note:'Different actual company returned'},p_request_id:randomUUID()},1);
 await run('final','collect_sale_payment',{p_sale_id:m.sale,p_payments:[{wallet_id:m.cash,amount:1750}],p_request_id:randomUUID()},1);
 await run('independent-request-namespace','accounting_operation',{p_payload:{action:'capital',amount:1,wallet_id:m.cash,date:today,description:'Independent Finance request namespace'},p_request_id:m.events.checkout.args.p_request_id},1);
 for(const [key,action,repay,account] of [['lent','loan_lend','loan_collect','loan_receivable'],['borrowed','loan_create','loan_repay','loan_payable']]){
  const loan=await run(`${key}-principal`,'accounting_operation',{p_payload:{action,amount:100.05,lender:'Three-business cent fixture',wallet_id:m.cash,date:today,description:'Principal ownership boundary',allocations:{logistics:33.33,lpg:33.33,stove:33.34}},p_request_id:randomUUID()},1);
  for(const [phase,amount] of [['partial',100.04],['last-cent',0.01]])await run(`${key}-${phase}`,'accounting_operation',{p_payload:{action:repay,loan_id:loan.id,amount,wallet_id:m.bank,date:today,description:'Exact principal settlement'},p_request_id:randomUUID()},1);
  assert.equal(sql(`select count(*) from(select business_category from public.accounting_lines where tenant_id=${uid(m.tenant_id)} and entity_id=${uid(loan.id)} and account='${account}' group by business_category having sum(amount)<>0)x;`),'0','Every business principal closes at the final cent');
 }
 const filters={from:today,to:today,category:'all',source:'sale',search:'Compact checkout fixture'};
 const activity=await checked(c.rpc('get_accounting_breakdown',{p_filters:filters,p_group:'all',p_side:'closing',p_mode:'history',p_offset:0,p_limit:100}));
 assert.equal(activity.total,4);const checkout=activity.entries.find(e=>e.description==='New sale');assert(checkout);assert.equal(checkout.line_count,7);assert.equal(checkout.amount,4250);
 const evidence=await checked(c.rpc('get_journal_lines',{p_filters:filters,p_journal_id:checkout.journal_id}));assert.equal(evidence.total,7);
 // Independent Gas issues each cost 808.33 externally plus 16.67 transport;
 // Package also issues an original Bottle at 1200. Refill Bottle becomes a claim.
 const cogs=evidence.entries.filter(e=>e.account_code==='cogs');assert.equal(cogs.length,1);assert.equal(cogs[0].amount,2850);assert.equal(cogs[0].consolidated_amount,2816.66);
 assert.equal(sql(`select coalesce(sum(amount),0) from public.accounting_lines where tenant_id=${uid(m.tenant_id)} and account='bottle_receivable' and entity_id=${uid(m.sale)};`),'0.00');
 const reconciliation=JSON.parse(sql(`select jsonb_build_object('cash',(select sum(balance) from public.wallets where tenant_id=${uid(m.tenant_id)}),'journal_cash',(select sum(amount) from public.accounting_lines where tenant_id=${uid(m.tenant_id)} and account='cash'),'bad_journals',(select count(*) from(select journal_id,business_category from public.accounting_lines where tenant_id=${uid(m.tenant_id)} group by 1,2 having sum(amount)<>0)x),'inventory',(select sum(remaining_value+remaining_internal_value) from app_private.fifo_layers where tenant_id=${uid(m.tenant_id)}),'journal_inventory',(select sum(amount) from public.accounting_lines where tenant_id=${uid(m.tenant_id)} and account='inventory_lpg'));`));
 assert.equal(reconciliation.cash,reconciliation.journal_cash);assert.equal(reconciliation.inventory,reconciliation.journal_inventory);assert.equal(reconciliation.bad_journals,0);
 browser=await chromium.launch({channel:'chrome',headless:true});const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});const page=await context.newPage();page.setDefaultTimeout(25000);const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(`${site}/?accounting-acceptance=${runId}#/login`);await page.locator('input[type=email]').fill(secret.email);await page.locator('input[type=password]').fill(secret.password);await page.locator('form button[type=submit]').click();await page.waitForURL(u=>!u.hash.includes('login'));
 for(const [width,theme] of [[1440,'light'],[768,'light'],[390,'light'],[375,'dark']]){
  await page.setViewportSize({width,height:width>500?1000:844});await page.goto(`${site}/?accounting-acceptance=${runId}#/finance`);await page.getByRole('navigation',{name:'Finance',exact:true}).getByRole('button',{name:'Accounting activity',exact:true}).click();
  await page.evaluate(t=>document.documentElement.setAttribute('data-theme',t),theme);
  await page.getByRole('navigation',{name:'Accounting activity view'}).getByRole('button',{name:'Historical activity',exact:true}).click();
  await page.getByPlaceholder('Name, product, description or reference').fill('Compact checkout fixture');
  await page.waitForFunction(()=>document.querySelectorAll('.accounting-entry-card').length===4);
  const card=page.locator('.accounting-entry-card').filter({has:page.getByRole('heading',{name:'New sale',exact:true})});await card.getByText('7 accounting lines',{exact:true}).waitFor();
  const fits=async()=>assert.deepEqual(await page.evaluate(()=>[document.documentElement,...document.querySelectorAll('dialog[open],.accounting-entry-card')].filter(e=>e.scrollWidth>e.clientWidth+2).map(e=>e.className)),[],'Responsive page/card/dialog overflow');
  await fits();await page.screenshot({animations:'disabled',path:`${folder}/activity-${width}-${theme}.png`});await card.screenshot({animations:'disabled',path:`${folder}/checkout-${width}-${theme}.png`});const height=(await card.boundingBox()).height;assert(height<(width>=1100?145:width>540?200:235),`Short action row at ${width}px is ${height}px high`);
  await card.locator('summary').click();await card.locator('tbody tr').first().waitFor();assert.equal(await card.locator('tbody tr').count(),7);await fits();if(width<540)assert(await card.locator('.accounting-table-wrap').evaluate(e=>e.scrollWidth<=e.clientWidth+2),'Phone journal lines hide amounts offscreen');await card.screenshot({animations:'disabled',path:`${folder}/expanded-${width}-${theme}.png`});
  if(width<540){const credit=card.locator('td[data-label="Credit"]:not(.journal-line-zero)').last();await credit.scrollIntoViewIfNeeded();const bounds=await credit.boundingBox();assert(bounds&&bounds.y>=0&&bounds.y+bounds.height<=844,'Last credit line cannot be reached on phone');await page.screenshot({animations:'disabled',path:`${folder}/expanded-tail-${width}-${theme}.png`});}
  await card.locator('summary').click();
  await card.getByRole('button',{name:'View source record',exact:true}).click();await page.getByRole('dialog').last().waitFor();await fits();await page.keyboard.press('Escape');
  await page.getByRole('button',{name:/^Advanced filters/}).click();const dialog=page.getByRole('dialog').last();await dialog.getByLabel('Account',{exact:true}).selectOption('customer_receivable');await dialog.getByLabel('Movement',{exact:true}).selectOption('decrease');await dialog.getByRole('button',{name:'Apply filters',exact:true}).click();
  await page.waitForFunction(()=>document.querySelectorAll('.accounting-entry-card').length===2);await fits();await page.getByRole('button',{name:'Reset',exact:true}).click();
  await page.getByRole('navigation',{name:'Accounting activity view'}).getByRole('button',{name:'Components',exact:true}).click();await page.locator('.accounting-entry-card').first().waitFor();await fits();
 }
 assert.deepEqual(errors,[]);assert.equal(preservation(),m.before_preservation,'Existing business accounting/wallet/FIFO evidence changed');
 m.reconciliation=reconciliation;m.verified_at=new Date().toISOString();persist();
 console.log('PASS actual Auth/PostgREST single-event posting, exact retry, split wallets, FIFO transport COGS, cross-company delayed bottles, collections and source reconciliation');
 console.log('PASS published desktop/tablet/phone light/dark activity, actual seven-line expansion, source drilldown, advanced filters and component view');
}finally{
 if(browser)await browser.close();await c.auth.signOut({scope:'global'}).catch(()=>{});
 if(m.verified_at&&!m.cleaned_at){
  const tables=sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1;").split('\n');assert(tables.every(t=>/^(public|app_private)\.[a-z0-9_]+$/.test(t)));
  sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id=${uid(m.tenant_id)} and p.user_id=${uid(m.user_id)} and business_name='${m.name}') then raise exception 'Non-fixture cleanup refused';end if;end$$;set local session_replication_role=replica;${tables.map(t=>`delete from ${t} where tenant_id=${uid(m.tenant_id)};`).join('\n')}set local session_replication_role=origin;delete from auth.users where id=${uid(m.user_id)};commit;`);
  m.cleaned_at=new Date().toISOString();persist();unlinkSync(credentials);console.log('PASS scoped fixture cleanup, preserving existing businesses and original acceptance records');
 }
}
