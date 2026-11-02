// Published acceptance for the reported ledger, category, commission and modal issues.
// Only one rate-only save is made in the separate retained financial lab, in a
// month with no LPG receipts. No customer/operator business is modified.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { chromium, devices } from 'playwright';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--vps'));
const env = parseEnv(readFileSync('deploy/.env.frontend','utf8')), secret = parseEnv(readFileSync('.env.financial-test','utf8'));
const api = 'https://api.lpg.144.79.249.4.sslip.io', base = 'https://floral-dew-443b.khandakarsifat.workers.dev';assert.equal(env.VITE_SUPABASE_URL,api);
const path='.temp/financial-business/manifest.json',m=JSON.parse(readFileSync(path,'utf8')),persist=()=>writeFileSync(path,JSON.stringify(m,null,2));assert.equal(m.tenant,'63907560-fbbd-4ac2-b22b-04bb08f0b123');
const c=createClient(api,env.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async p=>{const r=await p;assert(!r.error,r.error?.message);return r.data;};
await checked(c.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));
const profile=await checked(c.from('user_profiles').select('tenant_id').eq('user_id',(await c.auth.getUser()).data.user.id).single());assert.equal(profile.tenant_id,m.tenant);
if(m.correctionCommission&&!m.correctionCommission.done){await checked(c.rpc('set_monthly_commission',m.correctionCommission.args));m.correctionCommission.done=true;persist();}
assert.deepEqual((await checked(c.rpc('get_financial_catalog'))).categories.map(c=>c.name),['Withdrawal','Expense','Capital','Revenue','Equipment']);
const folder='.temp/financial-business/corrections';mkdirSync(folder,{recursive:true});const errors=[],httpErrors=[],results=[];
const browser=await chromium.launch({channel:'chrome',headless:true});let last;
const settle=async p=>{await p.waitForLoadState('networkidle');await p.waitForFunction(()=>!Array.from(document.querySelectorAll('.page-content,dialog[open]')).some(e=>/\bLoading\b/i.test(e.innerText)));};
const fits=async(p,label)=>{const bad=await p.evaluate(()=>[document.documentElement,...document.querySelectorAll('.page-content,dialog[open]')].filter(e=>e.scrollWidth>e.clientWidth+1).map(e=>e.className));assert.deepEqual(bad,[],label+' horizontal overflow');};
try{
 for(const theme of ['light','dark'])for(const width of [1440,375,320]){
  const ctx=await browser.newContext({...(width===1440?{viewport:{width,height:1000}}:{...devices['Pixel 7'],viewport:{width,height:900}}),colorScheme:theme,reducedMotion:'reduce'});
  const p=await ctx.newPage();last=p;p.setDefaultTimeout(25000);p.on('pageerror',e=>errors.push(e.message));p.on('response',r=>{if(r.status()>=400&&r.url().startsWith(api+'/rest/'))httpErrors.push({path:new URL(r.url()).pathname,status:r.status()});});
  await p.goto(base+'/#/login',{waitUntil:'networkidle'});await p.locator('input[type=email]').fill(secret.LPG_TEST_EMAIL);await p.locator('input[type=password]').fill(secret.LPG_TEST_PASSWORD);await p.locator('form button[type=submit]').click();await p.waitForURL(u=>!u.hash.includes('/login'));await settle(p);
  const go=async route=>{await p.goto(base+'/#/'+route,{waitUntil:'networkidle'});await p.locator({finance:'.finance-page',inventory:'.inventory-page',settings:'.settings-workspace'}[route]).waitFor();await settle(p);await p.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);};
  const shot=async name=>{await fits(p,name);await p.screenshot({path:`${folder}/${name}-${width}-${theme}.png`,animations:'disabled'});};
  await go('finance');const nav=p.getByRole('navigation',{name:'Finance',exact:true});assert.equal(await nav.getByRole('button').count(),4);assert.equal(await p.getByLabel('Organization',{exact:true}).count(),0);
  await p.getByRole('button',{name:'All time',exact:true}).click();await settle(p);await p.getByRole('button',{name:/^Period expense/}).click();await settle(p);assert(!/Cumulative/.test(await p.getByRole('dialog').last().getByRole('heading').first().innerText()));await shot('finance-breakdown');await p.keyboard.press('Escape');
  await nav.getByRole('button',{name:'Financial entries',exact:true}).click();await settle(p);assert(await p.locator('.financial-entries tbody tr').count()>0);await p.getByLabel('Entry category',{exact:true}).selectOption('withdrawal');await settle(p);assert.match(await p.locator('.financial-entries tbody').innerText(),/Home/);await shot('financial-entries');await p.getByLabel('Entry category',{exact:true}).selectOption('');await settle(p);await p.locator('.financial-entries .finance-entry-link').first().click();await settle(p);await shot('entry-details');await p.keyboard.press('Escape');
  await nav.getByRole('button',{name:'Wallet ledger',exact:true}).click();await settle(p);assert(await p.locator('.finance-ledger tbody tr').count()>0,'Wallet ledger must load actual rows');assert.equal(await p.getByText('Ledger could not be loaded.',{exact:true}).count(),0);await shot('wallet-ledger');
  await p.getByRole('button',{name:'Financial entry',exact:true}).click();let d=p.getByRole('dialog').last();await d.getByLabel('Type',{exact:true}).selectOption(m.types.Electricity.type_id);await shot('financial-entry-form');await p.keyboard.press('Escape');
  await go('settings');await p.getByRole('button',{name:'Financial types',exact:true}).click();await settle(p);await p.getByRole('button',{name:'Add custom type',exact:true}).click();d=p.getByRole('dialog').last();assert.deepEqual(await d.getByLabel('Fixed accounting category',{exact:true}).locator('option').allTextContents(),['Withdrawal','Expense','Capital','Revenue','Equipment']);await shot('five-categories');await p.keyboard.press('Escape');
  await go('inventory');await p.locator('button.inv-tile').first().click();await p.getByRole('dialog').first().waitFor();await settle(p);d=p.getByRole('dialog').first();assert.equal(await d.getByText('Recorded inventory value',{exact:true}).count(),0);assert.equal(await d.getByRole('button',{name:'Add product photo',exact:true}).count(),0);const product=await checked(c.rpc('get_product_inventory',{p_item_id:m.lpg}));
  assert.equal(await d.locator('.commission-rates').count(),1);assert.equal(await d.getByText('Invoice-month commission / unit',{exact:true}).count(),0);
  for(const kind of ['package','refill']){const price=product.buying_prices.find(x=>x.price_type===kind);assert.equal(price.commission_per_unit,product.commission[kind+'_rate']);if(!price.is_manual&&price.bottle_cost!=null)assert.equal(price.new_price,Math.max(0,Math.round((price.bottle_cost+price.overhead_per_unit-product.commission[kind+'_rate'])*100)/100));}
  await shot('lpg-product');
  await d.getByRole('button',{name:'Set monthly rates',exact:true}).click();await settle(p);let modal=p.getByRole('dialog').last();assert.equal(await modal.locator('input').count(),2);await shot('commission-form');
  if(!m.correctionCommission){
   const before=await checked(c.rpc('get_monthly_commissions',{p_item_id:m.lpg,p_month:'2026-11-01'}));assert.equal(before.quantity,0,'The rate-only live fixture month must have no receipts');
   await modal.getByLabel('Package commission (Tk)',{exact:true}).fill('55');await modal.getByLabel('Refill commission (Tk)',{exact:true}).fill('35');
   const request=p.waitForRequest(r=>r.url().endsWith('/rpc/set_monthly_commission')&&r.method()==='POST'),response=p.waitForResponse(r=>r.url().endsWith('/rpc/set_monthly_commission')&&r.request().method()==='POST');await modal.getByRole('button',{name:'Save monthly rates',exact:true}).click();
   m.correctionCommission={args:(await request).postDataJSON(),done:false};persist();assert((await response).ok());m.correctionCommission.done=true;persist();await settle(p);
   const after=await checked(c.rpc('get_monthly_commissions',{p_item_id:m.lpg,p_month:'2026-11-01'}));assert.equal(after.current.package_rate,55);assert.equal(after.current.refill_rate,35);assert.equal(after.total,before.total+1);
  }else await p.keyboard.press('Escape');
  await p.getByRole('dialog').first().getByText('Commission history',{exact:true}).click();await shot('commission-history');await p.keyboard.press('Escape');
  await p.getByRole('button',{name:'Stove Business',exact:true}).click();await settle(p);await p.locator('.stove-tile').first().click();await settle(p);d=p.getByRole('dialog').last();assert.equal(await d.locator('.stove-price-card').count(),2);assert.equal(await d.getByText('Recorded inventory value',{exact:true}).count(),0);await shot('stove-product');
  const retail=d.locator('.stove-price-card').first();await retail.getByRole('button',{name:'Edit',exact:true}).click();assert(Number(await retail.getByLabel('Retail selling price (Tk)',{exact:true}).inputValue())>0);await retail.getByRole('button',{name:'Cancel',exact:true}).click();
  await d.getByRole('button',{name:'Stock activity',exact:true}).click();await settle(p);const activity=d.locator('.stove-stock-activity');assert(await activity.locator('.stove-stock-row').count()>0);assert(!/Empty cylinders|Filled \/ products|FIFO revaluation|refill|cylinder/i.test(await activity.innerText()));await shot('stove-activity');
  const link=activity.locator('.stove-stock-row button').first();if(await link.count()){await link.click();await settle(p);assert.equal(await p.getByRole('dialog').count(),2);await fits(p,'Stove source record');await p.keyboard.press('Escape');}
  results.push({width,theme,passed:true});await ctx.close();
 }
 assert.deepEqual(errors,[]);assert.deepEqual(httpErrors,[]);writeFileSync(folder+'/results.json',JSON.stringify(results,null,2));console.log('PASS published Finance/Inventory corrections: real ledger and entries, exactly five categories, no organization selector, paired-rate save/history, LPG cleanup and Stove pricing/activity/source links at desktop/Android 375/320 in both themes');
}catch(e){if(last&&!last.isClosed()&&!last.url().includes('/login'))await last.screenshot({path:folder+'/failure.png'});throw e;}finally{await browser.close();await c.auth.signOut({scope:'local'});}
