// Read-only authenticated visual review. Opens forms/details but never saves.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';

assert(process.argv.includes('--vps'), 'Explicit --vps target required');
const phase = process.argv.includes('--before') ? 'before' : 'after';
const frontend = parseEnv(readFileSync('deploy/.env.frontend','utf8'));
const secret = {...parseEnv(readFileSync('.env.live-test','utf8')),...process.env};
const api = 'https://api.lpg.144.79.249.4.sslip.io', worker = process.env.LPG_BROWSER_BASE ?? 'https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(frontend.VITE_SUPABASE_URL,api);assert.equal(secret.LPG_TEST_EMAIL,'sifatsiam244@gmail.com');
const folder = `.temp/sitewide-contrast/${phase}`;mkdirSync(folder,{recursive:true});
const client = createClient(api,frontend.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const pages = [['','Dashboard'],['inventory','Inventory'],['pos','Point of Sale'],['sales','Sales'],['purchases','Purchases'],['customers','Customers'],['employees','Employees'],['finance','Finance'],['logistics','Logistics'],['settings','Settings']];
const modalActions = {inventory:'Add Item',purchases:'New Purchase',customers:'Add customer',finance:'Add wallet',logistics:'Add vehicle','gas-plants':'Add Gas Plant'};
const pageRoots = {'':'.dashboard-columns',inventory:'.inventory-page',pos:'.pos-page',sales:'.sales-page',purchases:'.purchases-page',customers:'.customers-page',employees:'.employee-page',finance:'.finance-page',logistics:'.logistics-page','gas-plants':'.inventory-page',settings:'.settings-workspace'};
const luminance = hex => { const raw=hex.replace('#','');const v=raw.length===3?[...raw].map(x=>x+x).join(''):raw;assert.match(v,/^[a-f0-9]{6}$/i,'Expected opaque hex colour');const rgb=[0,2,4].map(i=>parseInt(v.slice(i,i+2),16)/255).map(x=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4);return rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722; };
const contrast = (a,b) => {const x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);};
const settleDialog = async page => {
 await page.waitForFunction(()=>!Array.from(document.querySelectorAll('dialog[open], [role="dialog"]')).some(el=>/\bLoading\b/i.test(el.innerText)));
 await page.waitForLoadState('networkidle');
};
let browser;const results=[],errors=[];
try {
 const auth = await client.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD});if(auth.error)throw Error('Burner login failed');
 const membership = await client.from('user_profiles').select('tenant_id,is_active').eq('user_id',auth.data.user.id).single();assert(!membership.error&&membership.data.is_active);
 browser = await chromium.launch({channel:'chrome',headless:true});
 for(const theme of phase==='before'?['light']:['light','dark']) {
  const context = await browser.newContext({colorScheme:theme,reducedMotion:'reduce'});
  await context.addInitScript(({session,host})=>localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify(session)),{session:auth.data.session,host:new URL(api).host});
  const page = await context.newPage();page.on('pageerror',error=>errors.push(error.message));
  for(const width of [1440,375])for(const [route,title] of pages) {
   await page.setViewportSize({width,height:width===375?812:1050});
   await page.goto(`${worker}/?contrast-review=1#/${route}`,{waitUntil:'networkidle'});
   await page.getByRole('heading',{name:title,exact:true}).first().waitFor();
   await page.locator(pageRoots[route]).waitFor();
   await page.waitForLoadState('networkidle');
   await page.waitForFunction(()=>!Array.from(document.querySelectorAll('.page-content')).some(el=>/\bLoading\b/i.test(el.innerText)));
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1 && Array.from(document.querySelectorAll('.page-content')).every(e=>e.scrollWidth<=e.clientWidth+1)),`${route||'dashboard'} overflow at ${width}`);
   await page.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);
   const filename=`${route||'dashboard'}-${width}-${theme}.png`;await page.screenshot({path:`${folder}/${filename}`,animations:'disabled'});
   const palette = await page.evaluate(()=>{const css=getComputedStyle(document.documentElement);return Object.fromEntries(['--primary','--app-bg','--surface','--input-bg','--border-subtle','--border-strong','--text-main','--text-muted','--text-soft'].map(name=>[name,css.getPropertyValue(name).trim()]));});
   const ratios={text:contrast(palette['--text-main'],palette['--surface']),supportingText:contrast(palette['--text-muted'],palette['--surface']),fieldBorder:contrast(palette['--border-strong'],palette['--input-bg'])};
   if(phase==='after'){assert(ratios.text>=4.5&&ratios.supportingText>=4.5,`Text contrast below AA: ${JSON.stringify(ratios)}`);assert(ratios.fieldBorder>=3,`Field boundary contrast below 3:1: ${JSON.stringify(ratios)}`);}
   results.push({page:route||'dashboard',width,theme,screenshot:filename,palette,ratios});
   if(route==='employees') {
    const employee = page.locator('.employee-card').first();if(await employee.count()) {
     await employee.click();const dialog=page.getByRole('dialog',{name:'Employee profile',exact:true});await dialog.waitFor();
     await dialog.getByRole('region',{name:'Employee details',exact:true}).waitFor();await settleDialog(page);assert(await dialog.evaluate(el=>el.scrollWidth<=el.clientWidth+1),'Employee modal overflow');
     await page.screenshot({path:`${folder}/employee-modal-${width}-${theme}.png`,animations:'disabled'});
     results.push({modal:'Employee profile',width,theme});
    }
   } else if(modalActions[route]) {
    const trigger=page.getByRole('button',{name:modalActions[route],exact:true});
    if(await trigger.count()&&await trigger.isEnabled()) {
     await trigger.click();const dialog=page.getByRole('dialog').first();await dialog.waitFor();await settleDialog(page);
     if(route==='purchases') {
      const plant=dialog.getByRole('combobox',{name:'Destination plant',exact:true});
      const first=await plant.locator('option').evaluateAll(options=>options.find(option=>option.value&&!option.disabled)?.value);
      if(first){await plant.selectOption(first);await settleDialog(page);}
     }
     assert(await dialog.evaluate(el=>el.scrollWidth<=el.clientWidth+1),`${route} modal overflow at ${width}`);
     await page.screenshot({path:`${folder}/${route}-modal-${width}-${theme}.png`,animations:'disabled'});
     results.push({modal:route,width,theme});
    }
   } else if(route==='settings') {
    await page.getByRole('button',{name:'Business profile',exact:true}).click();await page.getByRole('region',{name:'Attendance settings'}).waitFor();
    await page.screenshot({path:`${folder}/attendance-settings-${width}-${theme}.png`,animations:'disabled'});results.push({page:'attendance-settings',width,theme});
    for(const name of ['Stove product types','Vehicle expenses','Financial types','Gas plants','LPG brands','Employee roles','Cylinder weights','Appearance']) {
      await page.getByRole('navigation',{name:'Settings sections'}).getByRole('button',{name,exact:true}).click();await page.waitForLoadState('networkidle');
      assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1 && Array.from(document.querySelectorAll('.page-content')).every(e=>e.scrollWidth<=e.clientWidth+1)),`${name} overflow at ${width}`);
      await page.screenshot({path:`${folder}/settings-${name.toLowerCase().replaceAll(' ','-')}-${width}-${theme}.png`,animations:'disabled'});results.push({page:'settings-'+name,width,theme});
    }
   }
  }
  await context.close();
 }
 const publicContext = await browser.newContext({viewport:{width:375,height:812}}),publicPage=await publicContext.newPage();
 for(const route of ['login','register']){await publicPage.goto(`${worker}/#/${route}`,{waitUntil:'networkidle'});await publicPage.screenshot({path:`${folder}/${route}-375-light.png`,animations:'disabled'});results.push({page:route,width:375,theme:'light'});}
 await publicContext.close();assert.deepEqual(errors,[]);
 writeFileSync(`${folder}/review.json`,JSON.stringify({phase,results},null,2));
 console.log(`PASS: ${results.length} read-only page/modal visual checks (${phase}), no horizontal overflow or browser errors; screenshots in ${folder}`);
}catch(error){console.error(String(error.message).replaceAll(secret.LPG_TEST_PASSWORD,'[redacted]').replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,'[redacted JWT]'));process.exitCode=1;}
finally{if(browser)await browser.close();await client.auth.signOut({scope:'local'});}
