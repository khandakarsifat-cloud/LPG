// Saved-record/modal review and real UI writes on the retained lab only.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {createClient} from '@supabase/supabase-js';
import {chromium} from 'playwright';
assert(process.argv.includes('--vps'),'Explicit --vps required');
const config=parseEnv(readFileSync('deploy/.env.frontend','utf8')),secret=parseEnv(readFileSync('.env.fifo-test','utf8'));
const path='.temp/fifo-business/manifest.json',m=JSON.parse(readFileSync(path,'utf8'));assert(m.seedComplete&&m.extrasComplete);
const api='https://api.lpg.144.79.249.4.sslip.io',base=process.env.LPG_BROWSER_BASE??'https://floral-dew-443b.khandakarsifat.workers.dev';assert.equal(config.VITE_SUPABASE_URL,api);
const c=createClient(api,config.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const auth=await c.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD});assert(!auth.error);
const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date()),folder='.temp/fifo-business/workflows';mkdirSync(folder,{recursive:true});
const persist=()=>writeFileSync(path,JSON.stringify(m,null,2));const add=(label,event)=>{if(!m.spec.events.some(e=>e.label===label)){m.spec.events.push({label,order:m.spec.events.length,...event});persist();}};
const browser=await chromium.launch({channel:'chrome',headless:true});const errors=[];
const context=await browser.newContext({viewport:{width:1440,height:1050},reducedMotion:'reduce'});await context.addInitScript(({session,host})=>localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify(session)),{session:auth.data.session,host:new URL(api).host});const page=await context.newPage();page.setDefaultTimeout(20000);page.on('pageerror',e=>errors.push(e.message));
const settled=async()=>{await page.waitForLoadState('networkidle');await page.waitForFunction(()=>!Array.from(document.querySelectorAll('.page-content,dialog[open]')).some(e=>/\bLoading\b/i.test(e.innerText)));};
const fits=async(label)=>assert(await page.evaluate(()=>[document.documentElement,...document.querySelectorAll('.page-content,dialog[open]')].every(e=>e.scrollWidth<=e.clientWidth+1)),label+' overflow');
const go=async(route,root)=>{await page.goto(base+'/#/'+route,{waitUntil:'networkidle'});await page.locator(root).waitFor();await settled();};
async function commit(label,name,action,events){
 if(m.spec.events.some(e=>e.label===label))return;
 const saved=m.browserRequests?.[label];let result;
 if(saved){const response=await c.rpc(saved.name,saved.args);if(response.error)throw Error(response.error.message);result=response.data;}
 else{
  const request=page.waitForRequest(r=>r.url().endsWith('/rpc/'+name)&&r.method()==='POST').catch(error=>({waitError:error}));
  const response=page.waitForResponse(r=>r.url().endsWith('/rpc/'+name)&&r.request().method()==='POST').catch(error=>({waitError:error}));
  await action();const original=await request;if(original.waitError)throw original.waitError;m.browserRequests??={};m.browserRequests[label]={name,args:original.postDataJSON()};persist();
  const completed=await response;if(completed.waitError)throw completed.waitError;result=await completed.json();assert(completed.ok(),JSON.stringify(result));
 }
 for(const [index,e] of events(result).entries())add(index===0?label:label+'-'+index,e);
}
try{
 await go('finance','.finance-page');
 await commit('browser-capital','move_wallet_money',async()=>{
  await page.getByRole('button',{name:'Adjust balance',exact:true}).click();let d=page.getByRole('dialog').last();await d.getByLabel('Purpose',{exact:true}).selectOption('capital');await d.getByLabel('Wallet',{exact:true}).selectOption(m.cash);await d.getByLabel('Amount (Tk)',{exact:true}).fill('1');await d.getByLabel('Reason / reference',{exact:true}).fill('Lab browser owner investment');await d.getByRole('button',{name:'Record adjustment',exact:true}).click();
 },()=>[{kind:'funding',wallet:m.cash,amount:1,date:today}]);
 await go('finance','.finance-page');
 const categories=await c.rpc('get_financial_catalog');const category=categories.data.types.find(x=>x.origin==='custom'&&x.is_active&&x.account==='operating_expense'&&/rent|other|business/i.test(x.name));
 await commit('browser-spending','record_financial_entry',async()=>{
  await page.getByRole('button',{name:'Financial entry',exact:true}).click();let d=page.getByRole('dialog').last();await d.getByLabel('Type',{exact:true}).selectOption(category.type_id);await d.getByLabel('Paid from wallet',{exact:true}).selectOption(m.bank);await d.getByLabel('Amount (Tk)',{exact:true}).fill('5');await d.getByLabel('Description / asset name',{exact:true}).fill('Lab browser operating expense');await d.getByRole('button',{name:'Review entry',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Record entry',exact:true}).click();
 },()=>[{kind:'spending',wallet:m.bank,amount:5,date:today}]);
 await go('pos','.pos-page');
 const customer=m.customers[0],stove=m.products.find(p=>p.category==='stove'&&p.index===0);
 await commit('browser-pos','create_pos_sale',async()=>{
  await page.getByRole('button',{name:'Stove Business',exact:true}).click();await page.getByRole('button',{name:/Lab single-burner stove/}).click();await page.getByPlaceholder('Phone, name, shop, address...').fill(customer.phone);await page.getByText('Lab wholesale shop 1',{exact:true}).click();await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Confirm',exact:true}).click();
 },r=>[{kind:'sale',id:r.sale_id,customer:customer.customer_id,date:today,amount:1850,lines:[{item:stove.id,type:'package',quantity:1}]},{kind:'collection',sale:r.sale_id,customer:customer.customer_id,wallet:m.cash,amount:1850,date:today}]);
 for(const theme of ['light','dark'])for(const width of [1440,375]){
  await page.setViewportSize({width,height:width===375?812:1050});
  for(const [route,root,selector,name] of [['inventory','.inventory-page','.inv-tile','product'],['sales','.sales-page','.sale-card','sale'],['purchases','.purchases-page','.purchase-card','purchase'],['customers','.customers-page','.customer-card','customer'],['employees','.employee-page','.employee-card','employee']]){
   await go(route,root);await page.evaluate(t=>document.documentElement.setAttribute('data-theme',t),theme);await page.locator(selector).first().click();await page.getByRole('dialog').last().waitFor();await settled();await fits(`${name} detail ${width} ${theme}`);await page.screenshot({path:`${folder}/${name}-${width}-${theme}.png`});
   if(route==='inventory'){
    await page.getByText('Buying-price history',{exact:true}).click();await settled();await fits('Buying-price history');
    await page.getByText('Commission history',{exact:true}).click();await page.getByLabel('Commission month',{exact:true}).fill('2026-10');await settled();await page.getByRole('button',{name:'Edit selected month',exact:true}).click();await fits('Monthly commission editor');await page.screenshot({path:`${folder}/monthly-commission-${width}-${theme}.png`});
    if(!m.monthlyBrowserSaved&&width===1440&&theme==='light'){
     const rate=page.getByLabel('Package commission (Tk)',{exact:true});const prior=await rate.inputValue();assert(Number(prior)>0);const response=page.waitForResponse(r=>r.url().endsWith('/rpc/set_monthly_commission'));await page.getByRole('button',{name:'Save monthly rates',exact:true}).click();assert((await response).ok());m.monthlyBrowserSaved=true;persist();
    }else await page.getByRole('button',{name:'Cancel',exact:true}).last().click();
   }
   if(route==='employees'){
    for(const label of ['Pay salary','Give bonus']){await page.getByRole('button',{name:label,exact:true}).click();await settled();await fits(label);await page.screenshot({path:`${folder}/${label.replace(' ','-')}-${width}-${theme}.png`});await page.getByRole('button',{name:'Profile',exact:true}).click();}
   }
   await page.keyboard.press('Escape');
  }
  console.log(`PASS saved-record and nested pricing/commission/payroll dialogs: ${width}px ${theme}`);
 }
 assert.deepEqual(errors,[]);m.browserWritesComplete=true;persist();console.log('PASS real browser owner investment, spending, committed stove checkout and protected historical monthly-rate save; original input events retained for independent reconciliation');
}catch(error){if(!page.url().includes('/login'))await page.screenshot({path:folder+'/failure.png'}).catch(()=>{});console.error(String(error.stack??error).replaceAll(secret.LPG_TEST_PASSWORD,'[redacted]'));console.error(await page.getByRole('dialog').allTextContents());process.exitCode=1;}
finally{await browser.close();await c.auth.signOut({scope:'local'});}
