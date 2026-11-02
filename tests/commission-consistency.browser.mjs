// Read-only acceptance of the reported Tk72/Tk200 split on the retained FIFO lab.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { chromium, devices } from 'playwright';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--vps'));
const env=parseEnv(readFileSync('deploy/.env.frontend','utf8')),secret=parseEnv(readFileSync('.env.fifo-test','utf8'));
const api='https://api.lpg.144.79.249.4.sslip.io',base='https://floral-dew-443b.khandakarsifat.workers.dev';assert.equal(env.VITE_SUPABASE_URL,api);
const manifest=JSON.parse(readFileSync('.temp/fifo-business/manifest.json','utf8'));
assert.equal(manifest.tenant,'a35af806-e5c5-42e6-b600-f57212e1cfc7');
const client=createClient(api,env.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async p=>{const r=await p;assert(!r.error,r.error?.message);return r.data;};
const auth=await checked(client.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));
assert.equal((await checked(client.from('user_profiles').select('tenant_id').eq('user_id',auth.user.id).single())).tenant_id,manifest.tenant);
const item='fbb51393-0ac3-45e9-8805-1a1c58415f95';
const product=await checked(client.rpc('get_product_inventory',{p_item_id:item}));
assert.equal(product.commission.package_rate,200);assert.equal(product.commission.refill_rate,200);
for(const row of product.buying_prices){assert.equal(row.commission_per_unit,200);assert.equal(row.new_price,row.price_type==='refill'?700:2200);}
const folder='.temp/fifo-business/one-commission';mkdirSync(folder,{recursive:true});
const browser=await chromium.launch({channel:'chrome',headless:true}),errors=[],results=[];let last;
const settle=async p=>{await p.waitForLoadState('networkidle');await p.waitForFunction(()=>!Array.from(document.querySelectorAll('dialog[open]')).some(e=>/\bLoading\b/i.test(e.innerText)));};
try{
 for(const theme of ['light','dark'])for(const width of [1440,375,320]){
  const context=await browser.newContext({...(width===1440?{viewport:{width,height:1000}}:{...devices['Pixel 7'],viewport:{width,height:900}}),colorScheme:theme,reducedMotion:'reduce'});
  const page=await context.newPage();last=page;page.on('pageerror',e=>errors.push(e.message));page.on('response',r=>{if(r.url().startsWith(api+'/rest/')&&r.status()>=400)errors.push(`${new URL(r.url()).pathname}: ${r.status()}`);});
  await page.goto(base+'/#/login',{waitUntil:'networkidle'});await page.locator('input[type=email]').fill(secret.LPG_TEST_EMAIL);await page.locator('input[type=password]').fill(secret.LPG_TEST_PASSWORD);await page.locator('form button[type=submit]').click();await page.waitForURL(u=>!u.hash.includes('/login'));
  await page.goto(base+'/#/inventory',{waitUntil:'networkidle'});await page.locator('.inventory-page').waitFor();await page.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);
  await page.locator('button.inv-tile[title^="Lab Bashundhara 12kg 20mm"]').click();const dialog=page.getByRole('dialog').first();await dialog.waitFor();await settle(page);
  const panel=dialog.locator('.product-costing');assert.equal(await panel.count(),1);assert.equal(await panel.locator('.commission-rates').count(),1);
  assert.equal(await panel.getByText('Invoice-month commission / unit',{exact:true}).count(),0);
  const money=s=>Number(s.replace(/[^\d.-]/g,''));
  assert.deepEqual((await panel.locator('.commission-rates strong').allTextContents()).map(money),[200,200]);
  assert.deepEqual((await panel.locator('.product-buying-heading strong').allTextContents()).map(money),[700,2200]);
  await panel.getByRole('button',{name:'Set monthly rates',exact:true}).click();await settle(page);let modal=page.getByRole('dialog').last();assert.equal(await modal.locator('input').count(),2);assert.equal(await modal.getByLabel('Package commission (Tk)',{exact:true}).inputValue(),'200');await page.keyboard.press('Escape');
  await panel.getByText('Commission history',{exact:true}).click();await panel.getByLabel('Commission month',{exact:true}).fill('2026-10');await settle(page);assert.match(await panel.locator('.commission-history').innerText(),/72/);
  assert.deepEqual((await panel.locator('.commission-rates strong').allTextContents()).map(money),[200,200],'Browsing history must not change the active pair');
  await panel.getByText('Commission history',{exact:true}).click();
  await panel.getByRole('button',{name:'Edit approximate price',exact:true}).first().click();modal=page.getByRole('dialog').last();await modal.getByRole('combobox').selectOption('automatic');assert.match(await modal.innerText(),/700/);await page.keyboard.press('Escape');
  assert.deepEqual(await page.evaluate(()=>[document.documentElement,...document.querySelectorAll('dialog[open]')].filter(e=>e.scrollWidth>e.clientWidth+1).map(e=>e.className)),[]);
  await panel.scrollIntoViewIfNeeded();await page.screenshot({path:`${folder}/active-pair-${width}-${theme}.png`,animations:'disabled'});results.push({width,theme,refill:700,package:2200,commission:200});await context.close();
 }
 assert.deepEqual(errors,[]);writeFileSync(folder+'/results.json',JSON.stringify(results,null,2));console.log('PASS live source product: active Tk200 pair, suggestions Tk700/Tk2200, editor/restore/history consistency, desktop/375/320 both themes, no API errors; no records changed');
}catch(error){if(last&&!last.isClosed()&&!last.url().includes('/login')){await last.screenshot({path:folder+'/failure.png'});console.error(await last.getByRole('dialog').allTextContents());}throw error;}finally{await browser.close();await client.auth.signOut({scope:'local'});}
