// Read-only authenticated acceptance. Never changes the burner or retained labs.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { chromium } from 'playwright';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--vps'),'Explicit primary VPS target required');
const env=parseEnv(readFileSync('deploy/.env.frontend','utf8'));
const api='https://api.lpg.144.79.249.4.sslip.io',base='https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(env.VITE_SUPABASE_URL,api);
const folder='.temp/directory-polish/live';mkdirSync(folder,{recursive:true});
const checked=async request=>{const {data,error}=await request;assert(!error,error?.message);return data;};
const browser=await chromium.launch({channel:'chrome',headless:true});const results=[],errors=[],httpErrors=[];
try {
 for(const [label,file,tenant] of [['burner','.env.live-test','832c1094-e732-418a-a044-22540d02a657'],['stove-lab','.env.financial-test','63907560-fbbd-4ac2-b22b-04bb08f0b123']]){
  const secret=parseEnv(readFileSync(file,'utf8'));const client=createClient(api,env.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
  const auth=await checked(client.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));
  const profile=await checked(client.from('user_profiles').select('tenant_id').eq('user_id',auth.user.id).single());assert.equal(profile.tenant_id,tenant);
  for(const [kind,fields] of [['sales',['date','amount','due','bottles','customer']],['purchase',['date','amount','due','supplier']],['employee',['name','salary','joined']]]){
   let totals={};
   for(const category of kind==='employee'?['all']:['all','lpg','stove'])for(const field of fields)for(const direction of ['asc','desc']){
    const data=await checked(client.rpc(`get_${kind}_directory`,{p_filters:{business_category:category,sort:`${field}_${direction}`},p_offset:0,p_limit:100}));totals[category]=data.total;
    let previous;
    for(const row of data.entries){
     if(kind!=='employee'&&category!=='all')assert.equal(row.business_category,category);
     const value=field==='date'?row.created_at:field==='amount'?Number(kind==='sales'?row.total_amount:row.total_cost):field==='due'?Number(kind==='sales'?row.due:row.status==='cancelled'?0:Math.max(0,row.payable_amount-row.paid_amount)):field==='bottles'?Number(row.outstanding_bottles):field==='salary'?Number(row.current_salary):field==='joined'?row.joining_date:field==='customer'?(row.sale_tier==='wholesale'&&row.shop_name?row.shop_name:row.name).toLowerCase():field==='supplier'?(row.company_name??row.supplier_name??'').toLowerCase():row.name.toLowerCase();
     if(previous!==undefined)assert(direction==='asc'?previous<=value:previous>=value,`${label} ${kind} ${field} ${direction}`);previous=value;
    }
   }
   if(kind!=='employee')assert.equal(totals.all,totals.lpg+totals.stove);
  }
  for(const theme of ['light','dark'])for(const width of [1440,375,320]){
   const ctx=await browser.newContext({viewport:{width,height:900},colorScheme:theme,reducedMotion:'reduce'});
   await ctx.addInitScript(session=>localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token',JSON.stringify(session)),auth.session);
   const p=await ctx.newPage();p.setDefaultTimeout(25000);p.on('pageerror',e=>errors.push(e.message));p.on('response',r=>{if(r.status()>=400&&r.url().startsWith(api+'/rest/'))httpErrors.push({path:new URL(r.url()).pathname,status:r.status()});});
   const settle=async()=>{await p.waitForLoadState('networkidle');await p.waitForFunction(()=>!Array.from(document.querySelectorAll('.page-content,dialog[open]')).some(e=>/\bLoading\b/i.test(e.innerText)));await p.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);};
   const shot=async name=>{assert(await p.evaluate(()=>[document.documentElement,...document.querySelectorAll('.page-content,dialog[open]')].every(e=>e.scrollWidth<=e.clientWidth+1)),name+' horizontal overflow');await p.screenshot({path:`${folder}/${label}-${name}-${width}-${theme}.png`});};
   for(const route of label==='burner'?['sales','purchases','employees']:['sales']){
    await p.goto(base+'/?directory-polish=1#/'+route);await p.locator(route==='sales'?'.sales-page':route==='purchases'?'.purchases-page:not(.sales-page)':'.employee-page').waitFor();await settle();
    assert.equal(await p.getByLabel('Sort by',{exact:true}).count(),1);await p.getByRole('button',{name:/Sort direction:/}).click();await settle();
    if(route!=='employees'){
     for(const category of ['lpg','stove','all']){await p.getByLabel('Business',{exact:true}).selectOption(category);await settle();}
     assert(await p.locator('.record-card').evaluateAll(cards=>cards.every(card=>{const h=card.querySelector('.purchase-card-header').getBoundingClientRect(),s=card.querySelector('.record-statuses').getBoundingClientRect(),m=card.querySelector('.purchase-card-meta').getBoundingClientRect();return s.top-h.bottom<=7&&m.top-s.bottom<=7;})));
    }
    await shot(route);
    if(label==='stove-lab'){
     await p.getByLabel('Business',{exact:true}).selectOption('stove');await settle();assert(await p.locator('.sale-card').count()>0);await p.locator('.sale-card').first().click();await settle();const dialog=p.getByRole('dialog');assert.equal(await dialog.getByText('Stove product',{exact:true}).count()>0,true);assert(!/refills|packages|Exchange cost|filled out/i.test(await dialog.innerText()));await shot('stove-sale-modal');
    }
   }
   results.push({label,width,theme,passed:true});await ctx.close();
  }
  await client.auth.signOut({scope:'local'});
 }
 assert.deepEqual(errors,[]);assert.deepEqual(httpErrors,[]);writeFileSync(folder+'/results.json',JSON.stringify(results,null,2));console.log('PASS published Auth/PostgREST: all sort directions and category counts; burner directories and retained stove sale modal at 1440/375/320 in both themes; no business mutations');
}finally{await browser.close();}
