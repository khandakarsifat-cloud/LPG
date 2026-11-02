// Read-only verification of the exact transaction shown in the user's screenshot.
import assert from 'node:assert/strict';
import {readFileSync,mkdirSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {createClient} from '@supabase/supabase-js';
import {chromium} from 'playwright';
assert(process.argv.includes('--vps'),'Explicit --vps required');
const f=parseEnv(readFileSync('deploy/.env.frontend','utf8')),s=parseEnv(readFileSync('.env.fifo-test','utf8'));
const api='https://api.lpg.144.79.249.4.sslip.io',worker='https://floral-dew-443b.khandakarsifat.workers.dev';assert.equal(f.VITE_SUPABASE_URL,api);
const c=createClient(api,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async p=>{const{data,error}=await p;if(error)throw Error(error.message);return data;};
const sale='d399524e-fc64-4809-ae2b-f5e2083d8c1b',folder='.temp/feature-audit';mkdirSync(folder,{recursive:true});let browser;
try{
 const auth=await checked(c.auth.signInWithPassword({email:s.LPG_TEST_EMAIL,password:s.LPG_TEST_PASSWORD}));
 const member=await checked(c.from('user_profiles').select('tenant_id,is_active').eq('user_id',auth.user.id).single());assert(member.is_active);assert.equal(member.tenant_id,'a35af806-e5c5-42e6-b600-f57212e1cfc7');
 const detail=await checked(c.rpc('get_sale_details',{p_sale_id:sale}));assert.equal(detail.sale_id,sale);assert.equal(detail.total_amount,4100);assert.equal(detail.sale_items.length,3);assert(detail.actor.full_name);
 browser=await chromium.launch({channel:'chrome',headless:true});const ctx=await browser.newContext({viewport:{width:1440,height:1000}});
 await ctx.addInitScript(s=>localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token',JSON.stringify(s)),auth.session);
 const page=await ctx.newPage();page.setDefaultTimeout(25000);const failures=[];page.on('pageerror',e=>failures.push(e.message));
 await page.route(api+'/rest/v1/**',r=>{const q=r.request(),name=new URL(q.url()).pathname.split('/').pop();if(q.method()==='POST'&&!/^(get_|list_|can_)/.test(name)){failures.push('Unexpected mutation '+name);return r.abort();}return r.continue();});
 await page.goto(worker+'/?reported-pos-regression=1#/sales');await page.locator('#sales-search').fill('D399524E');await page.locator(`[data-sale-id="${sale}"]`).waitFor();await page.locator(`[data-sale-id="${sale}"]`).click();
 const dialog=page.locator('dialog.transaction-detail-dialog');await dialog.getByText(detail.actor.full_name,{exact:true}).waitFor();await dialog.getByRole('button',{name:'Print receipt',exact:true}).waitFor();
 for(const width of [1440,375,320])for(const theme of ['light','dark']){
  await page.setViewportSize({width,height:1000});await page.evaluate(theme=>document.documentElement.dataset.theme=theme,theme);
  assert(await dialog.evaluate(d=>d.scrollWidth<=d.clientWidth+1),'Transaction dialog overflow');
  assert.equal(await dialog.getByRole('alert').count(),0);await page.screenshot({path:`${folder}/reported-pos-${width}-${theme}.png`});
 }
 assert.deepEqual(failures,[]);console.log('PASS exact reported POS #D399524E: total Tk 4,100, three original lines, actor, settlement and receipt control; 1440/375/320px light/dark; read-only');
}catch(e){console.error(String(e.message).replaceAll(s.LPG_TEST_PASSWORD,'[redacted]'));process.exitCode=1;}
finally{await browser?.close();await c.auth.signOut({scope:'local'});}
