// Published, authenticated browser acceptance on the retained isolated lab.
import assert from 'node:assert/strict';
import {readFileSync,mkdirSync,writeFileSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {chromium} from 'playwright';
import {createClient} from '@supabase/supabase-js';
assert(process.argv.includes('--vps'),'Explicit --vps target required');
const config=parseEnv(readFileSync('deploy/.env.frontend','utf8')),secret=parseEnv(readFileSync('.env.fifo-test','utf8'));
const api='https://api.lpg.144.79.249.4.sslip.io',worker=process.env.LPG_BROWSER_BASE??'https://floral-dew-443b.khandakarsifat.workers.dev';assert.equal(config.VITE_SUPABASE_URL,api);
const manifest=JSON.parse(readFileSync('.temp/fifo-business/manifest.json','utf8'));assert(manifest.seedComplete);
const folder='.temp/fifo-business/browser';mkdirSync(folder,{recursive:true});
const c=createClient(api,config.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const auth=await c.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD});assert(!auth.error);
const profile=await c.from('user_profiles').select('tenant_id,is_active,tenants(business_name)').eq('user_id',auth.data.user.id).single();assert.equal(profile.data.tenant_id,manifest.tenant);assert.equal(profile.data.tenants.business_name,'LPG FIFO Development Lab 2026-11-01');
const browser=await chromium.launch({channel:'chrome',headless:true});const errors=[],results=[];
const routes=[['','Dashboard'],['inventory','Inventory'],['pos','Point of Sale'],['sales','Sales'],['purchases','Purchases'],['customers','Customers'],['employees','Employees'],['finance','Finance'],['logistics','Logistics'],['settings','Settings']];
const modals={inventory:'Add Item',customers:'Add customer',purchases:'New Purchase',employees:'Add employee',finance:'Add wallet',logistics:'Add vehicle'};
const roots={'':'.dashboard-workspace',inventory:'.inventory-page',pos:'.pos-page',sales:'.sales-page',purchases:'.purchases-page',customers:'.customers-page',employees:'.employee-page',finance:'.finance-page',logistics:'.logistics-page',settings:'.settings-workspace'};
const settled=async page=>{await page.waitForLoadState('networkidle');await page.waitForFunction(()=>!Array.from(document.querySelectorAll('.page-content,dialog[open]')).some(e=>/\bLoading\b/i.test(e.innerText)));};
const fits=async(page,where)=>{
 const bad=await page.evaluate(()=>[document.documentElement,...document.querySelectorAll('.page-content,dialog[open]')].filter(e=>e.scrollWidth>e.clientWidth+1).map(e=>({class:e.className,width:e.clientWidth,content:e.scrollWidth})));
 assert.deepEqual(bad,[],where+' horizontal overflow');
};
try{
 for(const theme of ['light','dark'])for(const width of [1440,375]){
  const context=await browser.newContext({viewport:{width,height:width===375?812:1000},isMobile:width===375,hasTouch:width===375,colorScheme:theme,reducedMotion:'reduce',acceptDownloads:true});
  const page=await context.newPage();page.setDefaultTimeout(20000);page.on('pageerror',e=>errors.push(e.message));
  await page.goto(worker+'/#/login',{waitUntil:'networkidle'});
  await page.locator('input[type=email]').fill(secret.LPG_TEST_EMAIL);await page.locator('input[type=password]').fill(secret.LPG_TEST_PASSWORD);
  await page.locator('form button[type=submit]').click();await page.waitForURL(url=>!url.hash.includes('/login'));await settled(page);
  for(const [route,title] of routes){
   await page.goto(`${worker}/?fifo-lab=1#/${route}`,{waitUntil:'networkidle'});await page.locator(roots[route]).waitFor();await page.getByRole('heading',{name:title,exact:true}).first().waitFor();await settled(page);
   await page.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);await fits(page,`${route||'dashboard'} ${width} ${theme}`);
   await page.screenshot({path:`${folder}/${route||'dashboard'}-${width}-${theme}.png`,animations:'disabled'});
   const action=modals[route];if(action){const button=page.getByRole('button',{name:action,exact:true});if(await button.count()){
    await button.click();await page.getByRole('dialog').last().waitFor();await settled(page);await fits(page,`${route} modal ${width} ${theme}`);await page.screenshot({path:`${folder}/${route}-modal-${width}-${theme}.png`,animations:'disabled'});await page.keyboard.press('Escape');
   }else results.push({route,width,theme,missingModal:action});}
   if(route==='finance'){
    await page.getByRole('heading',{name:'Income performance',exact:true}).waitFor();
    if(width===375){
     for(const side of ['Opening position','Closing position']){await page.getByRole('group',{name:'Financial position',exact:true}).getByRole('button',{name:side,exact:true}).click();await page.getByRole('heading',{name:side,exact:true}).filter({visible:true}).waitFor();await fits(page,'Mobile '+side);}
    }
    const nav=page.getByRole('navigation',{name:'Finance',exact:true});assert.equal(await nav.getByRole('button').count(),4);
    for(const tab of ['Wallet ledger','Financial entries','Loans','Analysis']){await nav.getByRole('button',{name:tab,exact:true}).click();await settled(page);await fits(page,`Finance ${tab} ${width} ${theme}`);}
    const cards=page.locator('button.overview-summary:visible');assert(await cards.count()>=4);for(let index=0;index<await cards.count();index++){
     await cards.nth(index).click();await page.getByRole('dialog').last().waitFor();await settled(page);await fits(page,`Analysis breakdown ${index} ${width} ${theme}`);await page.keyboard.press('Escape');
    }
    await page.getByRole('button',{name:'Adjust balance',exact:true}).click();await settled(page);await fits(page,'Adjust balance');
    const purpose=page.getByRole('dialog').last().getByText('Purpose',{exact:true}).locator('..').locator('select');
    for(const value of ['opening','capital','correction']){await purpose.selectOption(value);await fits(page,'Classified balance purpose '+value);}
    await page.keyboard.press('Escape');
    if(width===1440&&theme==='light'){
     await page.getByRole('button',{name:'All time',exact:true}).click();await settled(page);await page.locator('.accounting-analysis[aria-busy=false]').waitFor();
     const download=page.waitForEvent('download');await page.getByRole('button',{name:'Export PDF',exact:true}).click();await(await download).saveAs(folder+'/finance-analysis.pdf');
    }
   }
   if(route==='customers'){
    for(const value of ['payment','bottle','both','none','all']){await page.getByLabel('Dues',{exact:true}).selectOption(value);await page.waitForTimeout(250);await settled(page);await fits(page,`Customer dues ${value} ${width} ${theme}`);}
   }
   if(route==='settings'){
    const sections=page.getByRole('navigation',{name:'Settings sections',exact:true});
    for(const label of await sections.getByRole('button').allTextContents()){
     await sections.getByRole('button',{name:label.trim(),exact:true}).click();await settled(page);await fits(page,`Settings ${label} ${width} ${theme}`);
     if(label.trim()==='Business profile'){await page.getByRole('button',{name:'Register device',exact:true}).click();await settled(page);await fits(page,'Attendance device registration');await page.keyboard.press('Escape');}
    }
   }
   if(route==='logistics'){
    await page.locator('.vehicle-card').first().click();await settled(page);const sections=page.getByRole('navigation',{name:'Vehicle details sections',exact:true});
    for(const label of ['Overview','Transit history','Assignments','Service trips']){
     await sections.getByRole('button',{name:label,exact:true}).click();await settled(page);await fits(page,`Vehicle ${label} ${width} ${theme}`);
     const entry=page.locator(label==='Transit history'?'.transit-card':'.service-trip-card');
     if(['Transit history','Service trips'].includes(label)&&await entry.count()){
      await entry.first().click();await page.getByRole('dialog').last().waitFor();await settled(page);await fits(page,'Saved '+label);await page.keyboard.press('Escape');
     }
    }
    await page.keyboard.press('Escape');await page.getByRole('navigation',{name:'Logistics sections',exact:true}).getByRole('button',{name:'Transits',exact:true}).click();await settled(page);await fits(page,'Transit directory');
   }
   results.push({route:route||'dashboard',width,theme,passed:true});
  }
  await context.close();console.log(`PASS published browser: ${width}px ${theme}, ten modules, primary forms, Finance tabs/breakdowns and customer dues filters`);
 }
 assert.deepEqual(errors,[],'Uncaught browser errors');writeFileSync(folder+'/results.json',JSON.stringify({tenant:manifest.tenant,results,errors},null,2));
}catch(error){for(const context of browser.contexts())for(const page of context.pages())if(!page.url().includes('/login'))await page.screenshot({path:folder+'/failure.png'}).catch(()=>{});throw error;}
finally{await browser.close();await c.auth.signOut({scope:'local'});}
