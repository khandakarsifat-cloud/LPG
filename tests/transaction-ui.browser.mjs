// Intercepted UI tests for changed read contracts, recovery and responsive dialogs.
// Real published Auth/API checks live in feature-audit-live.browser.mjs.
import {readFileSync,mkdirSync} from 'node:fs';
import {chromium} from 'playwright';
const base=process.env.LPG_BROWSER_BASE??'https://floral-dew-443b.khandakarsifat.workers.dev';
for(const folder of ['inventory-history','customer-ui','bottles'])mkdirSync('.temp/'+folder,{recursive:true});
const browser=await chromium.launch({channel:'chrome',headless:true});
try{
 for(const file of ['inventory-history.browser.cjs','customers.browser.cjs','bottles.browser.cjs']){
  const ctx=await browser.newContext({viewport:{width:1440,height:1000}}),page=await ctx.newPage();page.setDefaultTimeout(15000);
  try{await page.goto(base);const run=(0,eval)('('+readFileSync('tests/'+file,'utf8')+')');console.log(file,await run(page));}
  finally{await ctx.close();}
 }
}finally{await browser.close();}
