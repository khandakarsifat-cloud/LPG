// Read-only deployed acceptance with the documented burner; never submits a business mutation.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--vps'), 'Explicit --vps target required');
const f=parseEnv(readFileSync('deploy/.env.frontend','utf8')),b=parseEnv(readFileSync('deploy/.env.backend','utf8'));
const secrets={...parseEnv(readFileSync('.env.live-test','utf8')),...process.env};
const worker='https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(f.VITE_SUPABASE_URL,'https://api.lpg.144.79.249.4.sslip.io');assert.equal(b.VPS_PROJECT_DIR,'/opt/lpg');
assert.equal(secrets.LPG_TEST_EMAIL,'sifatsiam244@gmail.com');
const c=createClient(f.VITE_SUPABASE_URL,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async request=>{const {data,error}=await request;if(error)throw Error(`${error.code}: ${error.message}`);return data;};
const sql=q=>execFileSync('ssh',[...(b.VPS_SSH_KEY ? ['-i', b.VPS_SSH_KEY] : []),'-p',b.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${b.VPS_USER}@${b.VPS_HOST}`,
  'sudo -n docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input:q,encoding:'utf8'}).trim();
let browser,preservation,before;
try {
 const auth=await checked(c.auth.signInWithPassword({email:secrets.LPG_TEST_EMAIL,password:secrets.LPG_TEST_PASSWORD}));
 const membership=await checked(c.from('user_profiles').select('tenant_id,is_active,tenants(business_name)').eq('user_id',auth.user.id).single());
 assert(membership.is_active);assert.match(membership.tenant_id,/^[a-f0-9-]{36}$/i);await checked(c.rpc('get_my_permissions'));
 preservation='select jsonb_build_array('+['items','wallets','wallet_transactions','customers','sales','sale_items','purchases','purchase_items','purchase_activity'].map(table=>
   `(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from public.${table} r where tenant_id='${membership.tenant_id}'::uuid)`).join(',')+');';
 before=sql(preservation);
 console.log('PASS: burner Auth and trusted membership; configured VPS target verified');
 const customerFilters={search:'',tier:'all',sort:'name_asc',from:'',to:'',item_ids:null,transactions_min:'',transactions_max:'',refill_min:'',refill_max:'',package_min:'',package_max:''};
 const filters={customers:customerFilters,sales:{search:'',payment:'all',bottles:'all',from:'',to:'',sort:'date_desc',tier:'all'},purchases:{search:'',status:'all',payment:'all',from:'',to:'',sort:'date_desc'}};
 const rpc={customers:'get_customer_directory',sales:'get_sales_directory',purchases:'get_purchase_directory'};
 const records={};
 for(const route of Object.keys(filters)){
  records[route]=[];
  for(let offset=0;;offset+=25){const result=await checked(c.rpc(rpc[route],{p_filters:filters[route],p_offset:offset,p_limit:25}));records[route].push(...result.entries);if(offset+25>=result.total){assert.equal(records[route].length,result.total);break;}}
 }
 browser=await chromium.launch({channel:'chrome',headless:true});
 const context=await browser.newContext({viewport:{width:1366,height:900}}),page=await context.newPage();
 const errors=[],forbidden=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/rest/v1/**',async r=>{const req=r.request(),name=new URL(req.url()).pathname.split('/').pop();if(req.method()==='POST'&&!/^(get_|list_)/.test(name)){forbidden.push(name);await r.abort();}else await r.continue();});
 await page.goto(worker+'/?ui-live-acceptance=1#/login');
 await page.getByLabel('Email Address',{exact:true}).fill(secrets.LPG_TEST_EMAIL);await page.getByLabel('Password',{exact:true}).fill(secrets.LPG_TEST_PASSWORD);
 await page.getByRole('button',{name:'Sign In',exact:true}).click();await page.waitForURL(u=>u.hash!=='#/login');
 mkdirSync('.temp/ui-audit/live',{recursive:true});
 let checkedPages=0;
 for(const route of Object.keys(filters)){
  const selector=route==='customers'?'.customer-grid':'.purchases-grid',attribute=route==='customers'?'data-customer-id':route==='sales'?'data-sale-id':'data-purchase-id';
  await page.goto(worker+'/?ui-live-acceptance='+route+'#/'+route);await page.locator(selector+' > button').first().waitFor();
  const nav=page.getByRole('navigation',{name:route+' pages'});
  for(const [width,height] of [[320,568],[390,844],[600,400],[768,1024],[1024,768],[1366,900],[1440,600],[1920,1080]]){
   await page.setViewportSize({width,height});await page.waitForTimeout(180);
   await page.waitForFunction(s=>document.querySelector(s)?.getAttribute('aria-busy')==='false',selector);
   await nav.getByRole('button',{name:'Page 1',exact:true}).click();
   const capacity=await page.locator(selector).evaluate(g=>{const columns=getComputedStyle(g).gridTemplateColumns.split(/\s+/).length;return columns*(g.clientWidth<=600?Math.max(3,Math.ceil(10/columns)):3);});
   const allIds=[];
   for(let index=0;index<Math.ceil(records[route].length/capacity);index++){
    const expected=records[route].slice(index*capacity,(index+1)*capacity).map(row=>row[route==='customers'?'customer_id':route==='sales'?'sale_id':'purchase_id']);
    await page.waitForFunction(({selector,attribute,expected})=>{const g=document.querySelector(selector);return g?.getAttribute('aria-busy')==='false'&&JSON.stringify([...g.children].map(el=>el.getAttribute(attribute)))===JSON.stringify(expected);},{selector,attribute,expected});
    const ids=await page.locator(selector+' > button').evaluateAll((cards,attribute)=>cards.map(card=>card.getAttribute(attribute)),attribute);allIds.push(...ids);
    assert.equal(await nav.getByRole('button',{name:'Page '+(index+1),exact:true}).getAttribute('aria-current'),'page');
    assert((await nav.innerText()).includes(`${index*capacity+1}–${Math.min((index+1)*capacity,records[route].length)} of ${records[route].length}`));
    const geometry=await page.locator(selector).evaluate(g=>{const boxes=[...g.children].map(el=>el.getBoundingClientRect());return {heights:boxes.map(b=>b.height),widths:boxes.map(b=>b.width),overlap:boxes.some((a,i)=>boxes.some((b,j)=>j>i&&a.left<b.right&&a.right>b.left&&a.top<b.bottom&&a.bottom>b.top)),overflow:document.querySelector('.page-content').scrollWidth>document.querySelector('.page-content').clientWidth};});
    if(geometry.overlap||geometry.overflow)await page.screenshot({path:'.temp/ui-audit/live/layout-failure.png'});
    assert(!geometry.overlap&&!geometry.overflow,JSON.stringify({route,width,index,geometry}));assert(geometry.heights.every(h=>Math.abs(h-geometry.heights[0])<1));assert(geometry.widths.every(w=>Math.abs(w-geometry.widths[0])<1));
    checkedPages++;
    if(width===1366&&(index===0||route==='customers'&&[3,4].includes(index)))await page.screenshot({path:`.temp/ui-audit/live/${route}-${index+1}.png`});
    if(index<Math.ceil(records[route].length/capacity)-1)await nav.getByRole('button',{name:'Next page',exact:true}).click();else assert(await nav.getByRole('button',{name:'Next page',exact:true}).isDisabled());
   }
   assert.deepEqual(allIds,records[route].map(row=>row[route==='customers'?'customer_id':route==='sales'?'sale_id':'purchase_id']));
  }
  console.log(`PASS: ${route}, ${records[route].length} real records, all pages at eight viewport sizes`);
 }
 const brands=await checked(c.rpc('list_lpg_brands',{p_active_only:false}));
 for(const route of ['inventory','pos']){
  await page.setViewportSize({width:1366,height:900});await page.goto(worker+'/#/'+route);
  const selector=route==='inventory'?'.inv-tiles-grid':'.pos-products-grid';await page.locator(selector+' > .brand-row-start').first().waitFor();
  const grouping=await page.locator(selector).evaluate((g,route)=>{const first=g.firstElementChild.getBoundingClientRect();return [...g.querySelectorAll(':scope > .brand-row-start')].map(el=>({name:el.querySelector(route==='inventory'?'.inv-tile-brand':'.pos-product-title').textContent.trim(),left:el.getBoundingClientRect().left,expectedLeft:first.left}));},route);
  assert(grouping.every(g=>Math.abs(g.left-g.expectedLeft)<1));
  const names=grouping.map(g=>route==='inventory'?g.name:brands.find(b=>g.name.startsWith(b.brand_name+' '))?.brand_name);
  assert.deepEqual(names,brands.filter(b=>names.includes(b.brand_name)).map(b=>b.brand_name));
 }
 console.log('PASS: real Inventory/POS brands start new rows in Settings order');
 // Inspect the richest real purchase audit without changing any business data.
 const histories=await Promise.all(records.purchases.map(async p=>({purchase:p,events:await checked(c.rpc('get_purchase_activity',{p_purchase_id:p.purchase_id}))})));
 const chosen=histories.sort((a,b)=>b.events.length-a.events.length)[0];
 await page.setViewportSize({width:1366,height:900});await page.goto(worker+'/#/purchases');
 const search=page.getByLabel('Search purchases',{exact:true});await search.fill(chosen.purchase.company_name);
 await page.waitForTimeout(250);await page.waitForFunction(()=>document.querySelector('.purchases-grid')?.getAttribute('aria-busy')==='false');
 while(!await page.locator(`[data-purchase-id="${chosen.purchase.purchase_id}"]`).count())await page.getByRole('navigation',{name:'purchases pages'}).getByRole('button',{name:'Next page'}).click();
 await page.locator(`[data-purchase-id="${chosen.purchase.purchase_id}"]`).click();
 const history=page.getByRole('region',{name:'Activity history',exact:true}),events=[],walletEntries=[];
 for(let index=0;index<Math.ceil(chosen.events.length/6);index++){
  const expected=chosen.events.slice(index*6,index*6+6).map(e=>e.activity_id);
  await page.waitForFunction(expected=>JSON.stringify([...document.querySelectorAll('[data-activity-id]')].map(el=>el.dataset.activityId))===JSON.stringify(expected),expected);
  events.push(...await history.locator('[data-activity-id]').evaluateAll(els=>els.map(el=>el.dataset.activityId)));
  walletEntries.push(...await history.locator('[data-transaction-id]').evaluateAll(els=>els.map(el=>el.dataset.transactionId)));
  if(index<Math.ceil(chosen.events.length/6)-1)await history.getByRole('button',{name:'Next page',exact:true}).click();
 }
 assert.deepEqual(events,chosen.events.map(e=>e.activity_id));assert.deepEqual(walletEntries.sort(),chosen.events.flatMap(e=>e.wallet_entries.map(w=>w.transaction_id)).sort());assert.equal(new Set(walletEntries).size,walletEntries.length);
 console.log(`PASS: real purchase details, ${events.length} chronological events, ${walletEntries.length} wallet entries shown once`);
 await page.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click();
 // Stage a real checkout and exercise only local editing; Cancel prevents submission.
 await page.goto(worker+'/#/pos');await page.getByRole('button',{name:/^New Package for/,disabled:false}).first().click();
 const customer=records.customers[0];await page.getByPlaceholder('Phone, name, shop, address...').fill(customer.phone);await page.getByText(customer.name,{exact:true}).last().click();
 await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();
 const checkout=page.getByRole('dialog',{name:'Confirm Sale',exact:true});await checkout.getByRole('button',{name:'Advanced payments',exact:true}).click();
 const amount=checkout.getByLabel('Payment 1 amount',{exact:true});await amount.waitFor();assert.equal(await amount.evaluate(el=>getComputedStyle(el).textAlign),'left');
 await amount.fill('123.45');await amount.press('Home');await amount.press('ArrowRight');await amount.press('Delete');assert.equal(await amount.inputValue(),'13.45');await amount.press('Backspace');assert.equal(await amount.inputValue(),'3.45');await amount.press('Control+A');await amount.press('Backspace');assert.equal(await amount.inputValue(),'');
 await checkout.getByRole('button',{name:'Cancel',exact:true}).click();
 assert.deepEqual(forbidden,[]);assert.deepEqual(errors,[]);
 console.log(`PASS: ${checkedPages} authenticated directory pages, purchase audit and natural checkout editing; no business mutations`);
} catch(error) {
 console.error(String(error?.message??error).replaceAll(secrets.LPG_TEST_PASSWORD,'[redacted]'));process.exitCode=1;
} finally {
 if(browser)await browser.close();await c.auth.signOut({scope:'local'});
 if(before){assert.equal(sql(preservation),before,'Burner business data changed');console.log('PASS: original stock, wallets, ledger, customers, sales, purchase lines and activity fingerprints unchanged');}
}
