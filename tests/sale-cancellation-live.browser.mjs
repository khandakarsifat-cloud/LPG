// Real Auth/PostgREST and published browser acceptance in an identified disposable
// business. No retained-lab or existing-business mutations are permitted.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
assert(process.argv.includes('--vps'),'Explicit --vps required');
const env=parseEnv(readFileSync('deploy/.env.frontend','utf8')),backend=parseEnv(readFileSync('deploy/.env.backend','utf8'));
const credentials={...parseEnv(readFileSync('.env.live-test','utf8')),...process.env};
const api='https://api.lpg.144.79.249.4.sslip.io',worker='https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(env.VITE_SUPABASE_URL,api);assert.equal(backend.VPS_HOST,'144.79.249.4');assert.equal(backend.VPS_PROJECT_DIR,'/opt/lpg');
const ssh=[...(backend.VPS_SSH_KEY?['-i',backend.VPS_SSH_KEY]:[]),'-p',backend.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${backend.VPS_USER}@${backend.VPS_HOST}`];
const sql=input=>execFileSync('ssh',[...ssh,'sudo -n docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input,encoding:'utf8',maxBuffer:1024*1024}).trim();
const uuid=v=>{assert.match(v,/^[a-f0-9-]{36}$/);return `'${v}'::uuid`;};
const checked=async request=>{const {data,error}=await request;if(error)throw Error(error.message);return data;};
const make=()=>createClient(api,env.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const owner=make(),burner=make(),anon=make();
const folder='.temp/sale-cancellation';mkdirSync(folder,{recursive:true});
const tables=['public.items','public.inventory_movements','public.inventory_costs','public.sales','public.sale_items','public.customers','public.purchases','public.wallets','public.wallet_transactions','public.accounting_journals','public.accounting_lines','app_private.fifo_layers','app_private.fifo_consumptions'];
const preservation='select jsonb_build_array('+tables.map(t=>`(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from ${t} r)`).join(',')+');';
const before=sql(preservation),manifest={tenant:null,user:null,sales:[],products:[]};let browser;
const password=randomUUID()+'Aa1!';
try {
 const auth=await checked(burner.auth.signInWithPassword({email:credentials.LPG_TEST_EMAIL,password:credentials.LPG_TEST_PASSWORD}));
 const membership=await checked(burner.from('user_profiles').select('tenant_id,is_active').eq('user_id',auth.user.id).single());assert(membership.is_active&&membership.tenant_id);
 const signup=await checked(owner.auth.signUp({email:`sale-cancel-${randomUUID()}@example.invalid`,password}));manifest.user=signup.user.id;
 manifest.tenant=(await checked(owner.rpc('setup_business',{p_business_name:'Sale cancellation disposable acceptance '+randomUUID(),p_owner_name:'Cancellation fixture owner'}))).tenant_id;
 const persist=()=>writeFileSync(folder+'/manifest.json',JSON.stringify(manifest,null,2));persist();
 const wallet=(await checked(owner.rpc('get_payment_wallets'))).find(w=>w.type==='cash').wallet_id;
 for(const mode of ['none','partial','full','mixed','browser']){
  const brand=(await checked(owner.rpc('create_lpg_brand',{p_brand_name:'Cancellation '+mode,p_description:'Disposable cancellation acceptance'}))).brand_id;
  const item=(await checked(owner.from('items').insert({tenant_id:manifest.tenant,brand_id:brand,size_kg:12,mouth_size:'22mm'}).select('item_id').single())).item_id;manifest.products.push(item);persist();
  for(const payload of [{filled_quantity:0,empty_quantity:10,empty_unit_cost:1000},{filled_quantity:10,empty_quantity:0,filled_unit_cost:2500,empty_unit_cost:1800}])await checked(owner.rpc('adjust_inventory',{p_payload:{item_id:item,kind:'opening',reason:'Distinct original shell batches',...payload},p_request_id:randomUUID()}));
  await checked(owner.rpc('save_product_prices',{p_item_id:item,p_customer_tier:'retail',p_prices:{refill:{price:1300,mrp:null},package:{price:3000,mrp:null}},p_expected:{refill:null,package:null}}));
  const count=mode==='none'?0:mode==='full'?2:1,paid=mode==='partial'?500:mode==='full'?2600:0;
  const lines=[{item_id:item,type:'refill',quantity:2,unit_price:1300},{item_id:item,type:'empty_return',quantity:2,unit_price:0}];if(mode==='mixed'||mode==='browser')lines.push({item_id:item,type:'package',quantity:1,unit_price:3000});
  const sale=await checked(owner.rpc('create_pos_sale',{p_customer_phone:'01781111'+String(manifest.sales.length+1).padStart(3,'0'),p_customer_name:'Cancellation '+mode,p_customer_shop_name:null,p_customer_address:null,p_customer_tier:'retail',p_discount_amount:0,p_exchange_fee:0,p_notes:'Disposable '+mode+' acceptance',p_items:lines,p_customer_id:null,p_request_id:randomUUID(),p_payments:paid?[{wallet_id:wallet,amount:paid}]:[],p_bottles:{lines:count?[{received_item_id:item,quantity:count}]:[]}}));
  const row={id:sale.sale_id,item,mode,paid};manifest.sales.push(row);persist();
  if(mode==='browser')continue;
  const key=randomUUID(),args={p_sale_id:row.id,p_reason:'Disposable actual return',p_confirmation:'CANCEL',p_request_id:key};
  const result=await checked(owner.rpc('reverse_sale',args));assert.deepEqual(await checked(owner.rpc('reverse_sale',args)),result);assert.equal(Number(result.refund_due),paid);
  const inventory=await checked(owner.from('items').select('filled_quantity,empty_quantity').eq('item_id',item).single());assert.deepEqual(inventory,{filled_quantity:10,empty_quantity:10});
 }
 console.log('PASS real API: none/partial/full/mixed bottle receipts cancel, exact stock restored, original request retries');
 const foreign=await burner.rpc('reverse_sale',{p_sale_id:manifest.sales.at(-1).id,p_reason:'Foreign denial',p_confirmation:'CANCEL',p_request_id:randomUUID()});assert(foreign.error,'Foreign sale cancellation must reject');
 assert((await anon.rpc('reverse_sale',{p_sale_id:manifest.sales.at(-1).id,p_reason:'Anonymous denial',p_confirmation:'CANCEL',p_request_id:randomUUID()})).error,'Anonymous cancellation must reject');
 browser=await chromium.launch({channel:'chrome',headless:true});const errors=[];
 for(const width of [1440,375,320])for(const theme of ['light','dark']){
  const ctx=await browser.newContext({viewport:{width,height:900},colorScheme:theme});await ctx.addInitScript(session=>localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token',JSON.stringify(session)),signup.session);
  const p=await ctx.newPage();p.setDefaultTimeout(25000);p.on('pageerror',e=>errors.push(e.message));
  await p.goto(worker+'/?cancellation-acceptance=1#/sales');await p.locator('.sales-page').waitFor();const status=p.getByLabel('Status',{exact:true});await status.waitFor();assert.equal(await status.inputValue(),'all');assert.equal(await p.getByLabel('Money status',{exact:true}).count(),0);
  await p.waitForLoadState('networkidle');await p.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);
  if(width===1440&&theme==='light'){
   await p.locator(`[data-sale-id="${manifest.sales.at(-1).id}"]`).click();const detail=p.locator('dialog.transaction-detail-dialog');await detail.getByRole('button',{name:'Cancel sale',exact:true}).click();
   const confirmation=p.getByRole('dialog',{name:'Cancel this sale?',exact:true});await confirmation.getByLabel('Reason',{exact:true}).fill('Disposable browser return');await confirmation.getByLabel('Type exactly CANCEL',{exact:true}).fill('CANCEL');
   const request=p.waitForResponse(r=>r.url().endsWith('/rest/v1/rpc/reverse_sale'));await confirmation.getByRole('button',{name:'Cancel sale',exact:true}).click();assert.equal((await request).status(),200);await confirmation.waitFor({state:'detached'});
   await detail.getByText(/Cancelled · Refund due/).waitFor();await detail.getByRole('button',{name:'Back to Sales',exact:true}).click();
   await p.locator(`[data-sale-id="${manifest.sales.at(-1).id}"]`).getByText('Cancelled',{exact:true}).waitFor();
  }
  await status.selectOption('cancelled');await p.waitForFunction(()=>document.querySelectorAll('.sale-card').length===5&&Array.from(document.querySelectorAll('.sale-card .record-statuses')).every(e=>e.textContent==='Cancelled'));assert.equal(await p.locator('.sale-card').getByText('Cancelled',{exact:true}).count(),5);
  assert.equal(await p.locator('.sale-card').getByText('Bottles settled',{exact:true}).count(),0);
  assert(await p.evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth+1),'Page must not overflow');await p.screenshot({path:`${folder}/${width}-${theme}.png`});
  await status.selectOption('paid');await p.getByText('No sales match these filters.',{exact:true}).waitFor();assert.equal(await p.locator('.sale-card').count(),0);
  await status.selectOption('all');await p.waitForFunction(()=>document.querySelectorAll('.sale-card').length===5);
  await ctx.close();console.log(`PASS published browser ${width}px ${theme}: cancelled/all/paid filters, cancellation retained in directory`);
 }
 assert.deepEqual(errors,[]);
 for(const s of manifest.sales){const stock=await checked(owner.from('items').select('filled_quantity,empty_quantity').eq('item_id',s.item).single());assert.deepEqual(stock,{filled_quantity:10,empty_quantity:10});if(s.paid)await checked(owner.rpc('refund_sale',{p_sale_id:s.id,p_payments:[{wallet_id:wallet,amount:s.paid}],p_request_id:randomUUID()}));}
 assert((await checked(owner.from('wallets').select('balance').eq('tenant_id',manifest.tenant))).every(w=>Number(w.balance)===0));
 const t=uuid(manifest.tenant);
 assert.equal(sql(`select count(*) from public.inventory_costs where tenant_id=${t} and (filled_value<>25000 or empty_value<>10000);`),'0');
 assert.equal(sql(`select count(*) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=${t} group by j.journal_id having sum(l.amount)<>0 or sum(l.consolidated_amount)<>0;`),'');
 console.log('PASS live source stock/value and balanced journals; actual refunds settle separately; foreign/anonymous cancellation rejected');
}catch(error){console.error(String(error.stack??error).replaceAll(password,'[redacted]').replaceAll(credentials.LPG_TEST_PASSWORD,'[redacted]').replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g,'[redacted token]'));process.exitCode=1;}
finally{
 if(browser)await browser.close();await owner.auth.signOut({scope:'global'});await burner.auth.signOut({scope:'local'});
 if(manifest.tenant){
  const list=sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1;").split('\n');assert(list.every(t=>/^(public|app_private)\.[a-z_]+$/.test(t)));
  sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id=${uuid(manifest.tenant)} and p.user_id=${uuid(manifest.user)} and t.business_name like 'Sale cancellation disposable acceptance %') then raise exception 'Refusing non-fixture cleanup';end if;end$$;set local session_replication_role=replica;${list.map(t=>`delete from ${t} where tenant_id=${uuid(manifest.tenant)};`).join('\n')}commit;`);
 }
 if(manifest.user)sql(`delete from auth.users where id=${uuid(manifest.user)};`);
 assert.equal(sql(preservation),before,'Existing stock, wallets, sources and FIFO evidence must remain unchanged');
 console.log('PASS fixture-only cleanup; all original source and stock/financial fingerprints unchanged; burner and retained labs preserved');
}
