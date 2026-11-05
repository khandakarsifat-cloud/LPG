// Real Auth, API and published browser acceptance in one explicitly disposable business.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFileSync,writeFileSync,mkdirSync,existsSync,unlinkSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {execFileSync} from 'node:child_process';
import {chromium} from 'playwright';
import {createClient} from '@supabase/supabase-js';
import {provisionTestBusiness} from '../supabase/tests/trusted-test-provisioning.mjs';
assert(process.argv.includes('--vps'));
const f=parseEnv(readFileSync('deploy/.env.frontend','utf8')),b=parseEnv(readFileSync('deploy/.env.backend','utf8'));
const api='https://api.lpg.144.79.249.4.sslip.io',url=process.env.LPG_BROWSER_BASE??'https://floral-dew-443b.khandakarsifat.workers.dev';assert.equal(f.VITE_SUPABASE_URL,api);assert.equal(b.VPS_HOST,'144.79.249.4');
const folder='.temp/purchase-finance-ui';mkdirSync(folder,{recursive:true});const file=`${folder}/manifest.json`,secretFile=`${folder}/credentials.json`;
const m=existsSync(file)?JSON.parse(readFileSync(file,'utf8')):{name:`Purchase finance UI disposable acceptance ${randomUUID()}`,events:{}};assert(!m.cleaned_at,'This fixture has been cleaned; archive its manifest before a new run');
const persist=()=>writeFileSync(file,JSON.stringify(m,null,2));
const c=createClient(api,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async p=>{const {data,error}=await p;if(error)throw Error(error.message);return data;};
const ssh=[...(b.VPS_SSH_KEY?['-i',b.VPS_SSH_KEY]:[]),'-p',b.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${b.VPS_USER}@${b.VPS_HOST}`];
const sql=q=>execFileSync('ssh',[...ssh,'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
const uid=v=>{assert.match(v,/^[0-9a-f-]{36}$/);return `'${v}'::uuid`;};
let secret;
if(!m.tenant_id){secret={email:`ui-${randomUUID()}@example.invalid`,password:randomUUID()+'Aa9!'};const fixture=await provisionTestBusiness(c,{...secret,businessName:m.name,ownerName:'UI acceptance owner'});m.tenant_id=fixture.tenant_id;m.user_id=fixture.user.id;writeFileSync(secretFile,JSON.stringify(secret));persist();}
else{secret=JSON.parse(readFileSync(secretFile,'utf8'));await checked(c.auth.signInWithPassword(secret));}
const access=await checked(c.rpc('get_access_context'));assert.equal(access.tenant_id,m.tenant_id);assert.equal(access.business_name,m.name);
const core=JSON.parse(readFileSync('.temp/core-business/manifest.json','utf8'));
assert.notEqual(m.tenant_id,core.tenant_id);
if(process.argv.includes('--cleanup')){
 assert(m.verified_at,'Verify fixture before cleanup');await c.auth.signOut({scope:'global'});
 const tables=sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1").split('\n');assert(tables.every(v=>/^(public|app_private)\.[a-z_]+$/.test(v)));
 sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id=${uid(m.tenant_id)} and p.user_id=${uid(m.user_id)} and business_name like 'Purchase finance UI disposable acceptance %') then raise exception 'Nonfixture cleanup refused';end if;end$$;set local session_replication_role=replica;${tables.map(t=>`delete from ${t} where tenant_id=${uid(m.tenant_id)};`).join('\n')}set local session_replication_role=origin;delete from auth.users where id=${uid(m.user_id)};commit;`);
 m.cleaned_at=new Date().toISOString();persist();unlinkSync(secretFile);console.log('PASS only the explicitly created disposable UI business and Auth identity cleaned');process.exit(0);
}
const run=async(key,name,args)=>{m.events[key]??={name,args};persist();if(!m.events[key].result){m.events[key].result=await checked(c.rpc(name,m.events[key].args));persist();}return m.events[key].result;};
const today=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dhaka'}).format(new Date());
m.cash=(await checked(c.rpc('get_payment_wallets'))).find(w=>w.type==='cash').wallet_id;persist();
await run('capital','accounting_operation',{p_payload:{action:'capital',amount:10000,wallet_id:m.cash,date:today,description:'UI disposable fixture funds'},p_request_id:randomUUID()});
const brand=await run('brand','create_lpg_brand',{p_brand_name:'UI Fixture Gas',p_description:'Disposable UI test'});m.brand=typeof brand==='string'?brand:brand.brand_id;
await checked(c.rpc('save_business_catalog',{p_kind:'weight',p_id:null,p_name:'30',p_active:true,p_remove:false}));
for(const [key,size] of [['small',12],['large',30]])if(!m[key]){m[key]=(await checked(c.from('items').insert({tenant_id:m.tenant_id,brand_id:m.brand,size_kg:size,mouth_size:'22mm'}).select('item_id').single())).item_id;persist();}
const plant=await run('plant','create_gas_plant',{p_plant_name:'UI Fixture filling plant',p_brand_id:m.brand,p_location:'Dhaka'});m.plant=typeof plant==='string'?plant:plant.plant_id;persist();
const types=await checked(c.rpc('get_stove_product_types'));
m.stove=(await run('stove','save_stove_product',{p_payload:{name:'UI Fixture single stove',type_id:types[0].type_id},p_request_id:randomUUID()})).item_id;
m.completed=(await run('completed-purchase','create_purchase',{p_payload:{business_category:'stove',supplier_name:'UI Fixture supplier',request_id:randomUUID(),rebate_amount:20,items:[{item_id:m.stove,quantity:1,bottle_quantity:0,unit_price:200,bottle_unit_price:0}]}})).purchase_id;persist();
const detail=async id=>(await checked(c.rpc('get_purchases_by_ids',{p_ids:[id]})))[0];
await run('receive','receive_purchase',{p_purchase_id:m.completed,p_revision:(await detail(m.completed)).revision});
await run('payment','record_purchase_payment',{p_purchase_id:m.completed,p_payments:[{wallet_id:m.cash,amount:180}],p_request_id:randomUUID()});
const before=await detail(m.completed);const rebate=await c.rpc('set_purchase_rebate',{p_purchase_id:m.completed,p_payload:{amount:10,revision:before.revision},p_request_id:randomUUID()});assert.match(rebate.error?.message??'',/Completed purchase commission rebate is locked/);assert.equal((await detail(m.completed)).revision,before.revision);
assert.equal((await checked(c.rpc('get_purchase_settlement',{p_purchase_id:m.completed}))).can_rebate,false);
const browser=await chromium.launch({channel:'chrome',headless:true});const errors=[];const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});const page=await context.newPage();page.setDefaultTimeout(25000);page.on('pageerror',e=>errors.push(e.message));
const settled=async()=>{await page.waitForLoadState('networkidle');};
const fits=async label=>{const bad=await page.evaluate(()=>[document.documentElement,...document.querySelectorAll('dialog[open],.accounting-entry-card,.purchase-product-card')].filter(e=>e.scrollWidth>e.clientWidth+2).map(e=>({class:e.className,width:e.clientWidth,scroll:e.scrollWidth})));assert.deepEqual(bad,[],label);};
const nav=()=>page.getByRole('navigation',{name:'Finance',exact:true});
const go=async route=>{await page.goto(`${url}/?ui-acceptance=1#/${route}`);await settled();};
const commit=async(key,name,action)=>{
 if(m.events[key]?.result)return m.events[key].result;
 if(m.events[key]?.args)return run(key,name,m.events[key].args);
 const capture=request=>{if(request.url()===`${api}/rest/v1/rpc/${name}`){m.events[key]={name,args:request.postDataJSON()};persist();}};
 page.on('request',capture);try{const pending=page.waitForResponse(r=>r.url()===`${api}/rest/v1/rpc/${name}`);await action();const response=await pending;const data=await response.json();assert(response.ok(),data.message);m.events[key].result=data;persist();await settled();return data;}finally{page.off('request',capture);}
};
try{
 await go('login');await page.locator('input[type=email]').fill(secret.email);await page.locator('input[type=password]').fill(secret.password);await page.locator('form button[type=submit]').click();await page.waitForURL(u=>!u.hash.includes('login'));await settled();
 for(const [width,theme] of [[1440,'light'],[768,'light'],[390,'light'],[375,'dark']]){
  await page.setViewportSize({width,height:width>500?1000:844});await go('purchases');await page.evaluate(t=>document.documentElement.setAttribute('data-theme',t),theme);
  await page.getByRole('button',{name:'New Purchase',exact:true}).click();await page.getByRole('button',{name:'LPG purchase',exact:true}).click();let d=page.getByRole('dialog').last();await d.getByLabel('Destination plant',{exact:true}).waitFor();
  const gap=await d.locator('.purchase-section').first().evaluate(e=>{const input=e.querySelector('select').getBoundingClientRect(),box=e.getBoundingClientRect();return box.bottom-input.bottom;});assert(gap>=12,'Destination field needs bottom padding');
  await d.getByLabel('Destination plant',{exact:true}).selectOption(m.plant);
  for(const [index,id,gas,bottles,price,bottlePrice] of [[1,m.small,'2','2','111','222'],[2,m.large,'3','3','333','444']]){
   await d.getByRole('button',{name:'Add product',exact:true}).click();await d.getByLabel(`Product ${index}`,{exact:true}).selectOption(id);const card=d.getByRole('article',{name:`Product ${index} details`,exact:true});
   await card.getByLabel('Gas quantity',{exact:true}).fill(gas);await card.getByLabel('Additional Bottle quantity',{exact:true}).fill(bottles);await card.getByLabel('Gas unit price (Tk)',{exact:true}).fill(price);await card.getByLabel('Bottle unit price (Tk)',{exact:true}).fill(bottlePrice);assert.match(await card.locator('.purchase-stock-caption').innerText(),/Filled = 0.*Empty = 0/);
  }
  assert.equal(await d.getByText(/empties required/).count(),0);await fits(`Purchase form ${width} ${theme}`);await page.screenshot({path:`${folder}/purchase-${width}-${theme}.png`});
  if(width===1440 && !m.events['browser-purchase']?.result){const result=await commit('browser-purchase','create_purchase',async()=>{await d.getByRole('button',{name:'Create purchase',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Create purchase',exact:true}).click();});const p=await detail(result.purchase_id);assert.deepEqual(p.items.map(l=>[l.item_id,l.unit_price,l.bottle_unit_price]).sort(),[[m.small,111,222],[m.large,333,444]].sort());}
  else await page.keyboard.press('Escape');
  await go('finance');await nav().getByRole('button',{name:'Accounting activity',exact:true}).click();await settled();await page.locator('.accounting-entry-card').first().waitFor();await fits(`Activity ${width} ${theme}`);await page.screenshot({path:`${folder}/activity-${width}-${theme}.png`});await page.locator('.accounting-entry-card').first().screenshot({path:`${folder}/entry-card-${width}-${theme}.png`});
  await page.getByRole('button',{name:/^Advanced filters/}).click();await page.screenshot({path:`${folder}/filters-${width}-${theme}.png`});await page.getByLabel('Account',{exact:true}).selectOption('supplier_payable');await page.getByLabel('Movement',{exact:true}).selectOption('decrease');await fits('Advanced filter dialog');await page.getByRole('dialog').last().getByRole('button',{name:'Apply filters',exact:true}).click();await page.waitForFunction(()=>{const labels=[...document.querySelectorAll('.accounting-entry-amount > span')];return labels.length>0 && labels.every(e=>e.textContent==='Decrease');});await settled();await fits('Activity filters');
  await page.getByRole('button',{name:'Reset',exact:true}).click();await page.getByLabel('Search all entries',{exact:true}).fill('thiswillnotmatch-any-source');await settled();await page.getByRole('heading',{name:'No matching entries',exact:true}).waitFor();await page.getByRole('button',{name:'Reset filters',exact:true}).click();await settled();
  await page.getByRole('navigation',{name:'Accounting activity view'}).getByRole('button',{name:'Components',exact:true}).click();await settled();await page.locator('.accounting-entry-card').first().waitFor();await fits('Components');await page.getByRole('button',{name:'View activity',exact:true}).first().click();await settled();await page.getByRole('button',{name:'Clear component',exact:true}).waitFor();await fits('Focused component');
  await nav().getByRole('button',{name:'Analysis',exact:true}).click();await page.locator('.accounting-analysis[aria-busy=false]').waitFor();await page.locator('button.overview-summary:visible').first().click();await settled();await page.getByRole('dialog').last().getByRole('button',{name:'Historical activity',exact:true}).click();await settled();await fits('Analysis breakdown');await page.screenshot({path:`${folder}/breakdown-${width}-${theme}.png`});await page.keyboard.press('Escape');
  await nav().getByRole('button',{name:'Loans & lending',exact:true}).click();await page.getByRole('navigation',{name:'Loan direction'}).getByRole('button',{name:'Money lent',exact:true}).click();await settled();await page.getByRole('button',{name:'Lend money',exact:true}).click();await fits('Lending form');await page.screenshot({path:`${folder}/lend-${width}-${theme}.png`});await page.keyboard.press('Escape');
 }
 await page.setViewportSize({width:390,height:844});await go('finance');await nav().getByRole('button',{name:'Loans & lending',exact:true}).click();await page.getByRole('button',{name:'Money lent',exact:true}).click();
 const lend=await commit('browser-lend','accounting_operation',async()=>{await page.getByRole('button',{name:'Lend money',exact:true}).click();const d=page.getByRole('dialog').last();await d.getByLabel('Borrower name',{exact:true}).fill('UI Fixture borrower');await d.getByLabel('Amount (Tk)',{exact:true}).fill('123.45');await d.getByLabel('Pay from wallet',{exact:true}).selectOption(m.cash);await d.getByRole('button',{name:'Review operation',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Record operation',exact:true}).click();});
 const collection=async(key,amount)=>commit(key,'accounting_operation',async()=>{await page.getByRole('button',{name:'Collect repayment',exact:true}).click();const d=page.getByRole('dialog').last();await d.getByLabel('Amount (Tk)',{exact:true}).fill(amount);await d.getByLabel('Receive into wallet',{exact:true}).selectOption(m.cash);await d.getByRole('button',{name:'Review operation',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Record operation',exact:true}).click();});
 await collection('browser-collect-partial','23.45');let register=await checked(c.rpc('get_accounting_register',{p_kind:'lending'}));assert.equal(register.entries.find(l=>l.loan_id===lend.id).outstanding,m.events['browser-collect-final']?.result?0:100);await fits('Partial repayment card');if(!m.events['browser-collect-final']?.result)await page.screenshot({path:`${folder}/lending-partial-phone.png`});
 await page.getByRole('button',{name:'History',exact:true}).click();await page.getByRole('dialog').last().getByText('repayment received',{exact:true}).first().waitFor();await fits('Lending history');await page.keyboard.press('Escape');await collection('browser-collect-final','100');register=await checked(c.rpc('get_accounting_register',{p_kind:'lending'}));assert.equal(register.entries.find(l=>l.loan_id===lend.id).outstanding,0);
 await go('purchases');await page.getByLabel('Business',{exact:true}).selectOption('stove');await settled();await page.locator(`[data-purchase-id="${m.completed}"]`).click();await settled();assert.equal(await page.getByRole('button',{name:'Save rebate',exact:true}).count(),0);assert.match(await page.getByRole('dialog').last().innerText(),/commission rebate are locked/);await fits('Completed purchase');
 assert.equal(sql(`select count(*) from public.accounting_lines where tenant_id=${uid(m.tenant_id)} group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0`),'');
 const report=await checked(c.rpc('get_finance_analysis',{p_filters:{from:today,to:today,category:'all'}}));assert.equal(report.closing.cash,9820);assert.equal(report.closing.revenue,20);assert.equal(report.closing.assets,10020);assert.equal(report.closing.equity,10020);assert.equal(report.closing.liabilities,0);
 assert.deepEqual(errors,[]);m.verified_at=new Date().toISOString();persist();console.log('PASS real published desktop/tablet/phone light/dark purchase cards, independent product prices, activity search/filters/components/source drilldowns, lending/partial/full repayment/history and completed rebate lock; journals and wallet reconcile');
}finally{await browser.close();await c.auth.signOut({scope:'local'});}
