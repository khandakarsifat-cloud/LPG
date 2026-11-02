// Intercepted rendering/interaction acceptance; the PostgreSQL/API suites own
// financial assertions. This test sends no requests to a real business backend.
import assert from 'node:assert/strict';
import {readFileSync,existsSync,mkdirSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {chromium} from 'playwright';
const base=process.env.LPG_BROWSER_BASE??'http://127.0.0.1:5174';
const env={...parseEnv(readFileSync('.env','utf8')),...(existsSync('.env.local')?parseEnv(readFileSync('.env.local','utf8')):{}),...process.env};
const host=new URL(env.VITE_SUPABASE_URL).host;const id=n=>`be000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const user={id:id(1),email:'unified-ui@example.invalid',aud:'authenticated',role:'authenticated',app_metadata:{},user_metadata:{},created_at:new Date().toISOString()};
const token='eyJhbGciOiJIUzI1NiJ9.'+Buffer.from(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,role:'authenticated'})).toString('base64url')+'.fixture';
const session={access_token:token,refresh_token:'fixture',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,token_type:'bearer',user};const tenant=id(2);const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date());
const wallets=[{tenant_id:tenant,wallet_id:id(3),name:'Cash Register',type:'cash',kind:'cash',balance:10000,opening_balance:10000,is_active:true,revision:1,details:''}];
const stove={tenant_id:tenant,item_id:id(4),business_category:'stove',product_name:'Fixture double stove',product_type_id:id(5),filled_quantity:10,empty_quantity:0};
const pool={filled_quantity:10,empty_quantity:0,filled_value:1000,empty_value:0,estimated:false};
const opening={capital:11000,revenue:0,expenses:0,withdrawals:0,other_equity:0,accumulated_income:0,assets:11000,liabilities:0,equity:11000,cash:10000,accounts:[{tenant_id:tenant,account:'cash',name:'Wallet cash',kind:'asset',entity_id:id(3),amount:10000},{tenant_id:tenant,account:'inventory_stove',name:'Stove inventory',kind:'asset',entity_id:id(4),amount:1000},{tenant_id:tenant,account:'opening_equity',name:'Opening equity',kind:'equity',entity_id:null,amount:11000}]};
const closing={...opening,assets:11200,equity:11200,cash:10200,revenue:500,expenses:300,accumulated_income:200,accounts:opening.accounts.map(a=>a.account==='cash'?{...a,amount:10200}:a)};
const calls=[];const errors=[];mkdirSync('.temp/unified-accounting',{recursive:true});
const browser=await chromium.launch({channel:'chrome',headless:true});const context=await browser.newContext({viewport:{width:1440,height:1050},acceptDownloads:true});
await context.addInitScript(({session,host})=>localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify(session)),{session,host});const page=await context.newPage();page.setDefaultTimeout(15000);page.on('pageerror',e=>errors.push(e.message));
await page.route('**/storage/v1/**',async route=>{calls.push({name:'storage',method:route.request().method(),path:new URL(route.request().url()).pathname});await route.fulfill({json:{Key:'fixture',Id:id(52)}});});
await page.route('**/auth/v1/**',route=>route.fulfill({json:user}));
await page.route('**/rest/v1/**',async route=>{const request=route.request();const url=new URL(request.url());const name=url.pathname.split('/').pop();const args=request.method()==='POST'?request.postDataJSON():{};calls.push({name,args});let data=[];
 if(name==='user_profiles')data=[{tenant_id:tenant,email:user.email,full_name:'Fixture owner',tenants:{business_name:'Unified fixture business'}}];
 else if(name==='get_my_permissions')data=['finance:view','finance:manage','inventory:view','inventory:manage','pos:sell','sales:view','receipts:print','purchases:view','purchases:manage','settings:manage','logistics:view','logistics:manage'];
 else if(name==='get_my_preferences')data={theme:'light'};
 else if(name==='can_cancel_purchases')data=true;
 else if(name==='get_analysis_businesses')data=[{tenant_id:tenant,business_name:'Unified fixture business'}];
 else if(name==='wallets'||name==='get_payment_wallets')data=wallets;
 else if(name==='get_finance_analysis')data={from:args.p_filters.from,to:args.p_filters.to,category:args.p_filters.category,opening,closing,all_time:!!args.p_filters.all_time,period_income:200,complete:true,estimated:false,missing_asset_values:0,invested_capital:0,capital_recorded:0,withdrawals_to_date:0,retained_earnings:200,coverage:[{tenant_id:tenant,started_at:today+'T00:00:00+06:00',note:'Verified opening'}],totals:{revenue:500,expenses:300,profit:200,contributions:0,withdrawals:0,equity_adjustments:0,cash_in:500,cash_out:100,cash_flow:400,transfers:100,position_profit:200},categories:[{account:'sales_revenue',name:'Product revenue',kind:'income',amount:500},{account:'cogs',name:'Cost of goods sold',kind:'expense',amount:300}],cash_categories:[{category:'operating',received:500,spent:100,net:400}],trend:[{period:today,period_start:today,period_end:today,assets:11200,liabilities:0,revenue:500,expenses:300,cash_flow:400,cash_in:500,cash_out:100,profit:200,net_worth:11000}],businesses:[{tenant_id:tenant,business_category:'stove',revenue:500,expenses:300}]};
 else if(name==='get_accounting_breakdown'){
  const p=args.p_side==='opening'?opening:closing;const values={assets:p.assets,liabilities:p.liabilities,equity:p.equity,cash:p.cash,capital:p.capital,inventory:1000,revenue:p.revenue,expenses:p.expenses,withdrawals:0,other_equity:0,accumulated_income:args.p_side==='period'?200:p.accumulated_income};const balance=values[args.p_group]??0;
  data={cutoff:args.p_side==='opening'?'2026-09-30':today,balance,original_opening:false,filtered_movement:balance,total:23,entries:Array.from({length:Math.min(20,23-(args.p_offset??0))},(_,i)=>({tenant_id:tenant,account:'capital',name:'Recorded contribution',entity_id:id(80+i+(args.p_offset??0)),entity_name:'Recorded component '+(i+1+(args.p_offset??0)),amount:balance/23,record_kind:args.p_group==='dues'?'loan':null,record_id:id(80),...(args.p_mode==='history'?{journal_id:id(30),line_no:i,entry_no:1,occurred_on:today,description:'Historical fixture activity',source:'capital',source_id:id(31)}:{})}))};
 }
 else if(name==='get_accounting_history')data={total:1,entries:[{action:'receipt',amount:1000,occurred_on:today}]};
 else if(name==='get_accounting_health')data={pending:0,snapshots:12,total:0,entries:[]};
 else if(name==='get_analysis_details')data={total:1,sources:['sale'],entries:[{journal_id:id(30),entry_no:1,source_id:id(31),transaction_reference:id(31),occurred_on:today,created_at:today+'T12:00:00Z',description:'Recorded fixture journal',source:'sale',estimated:false,line_count:2,total_debit:500}]};
 else if(name==='get_journal_lines')data={total:2,entries:[{line_no:1,account:'Customer receivables',entity_name:'Fixture buyer',amount:500,business_category:'stove'},{line_no:2,account:'Product revenue',entity_name:'Product revenue',amount:-500,business_category:'stove'}]};
 else if(name==='get_accounting_register')data={total:args.p_kind==='loans'?1:0,entries:args.p_kind==='loans'?[{loan_id:id(7),lender:'Fixture lender',principal:5000,outstanding:3000,description:'Fixture loan',received_on:today,opening:false}]:[]};
 else if(name==='get_accounting_history')data={total:0,entries:[]};
 else if(name==='items')data=request.method()==='POST'?{...args,item_id:id(50)}:url.searchParams.get('business_category')==='eq.stove'?[stove]:[];
 else if(name==='get_stove_product_types')data=[{type_id:id(5),name:'Double Stove',is_active:true}];
 else if(name==='get_inventory_valuation')data={known_value:1000,filled_value:1000,empty_value:0,lpg_value:0,stove_value:1000,reconstructed_products:0,unvalued_units:0,inverted_products:0};
 else if(name==='get_inventory_cost_history')data={pool,total:1,entries:[{entry_id:id(9),occurred_on:today,filled_change:10,empty_change:0,filled_value:1000,empty_value:0,reason:'Verified opening',estimated:false}]};
 else if(name==='get_monthly_commissions')data={current:null,quantity:0,total:0,entries:[]};
 else if(name==='get_product_inventory')data={can_manage_prices:true,commission:{refill_rate:0,package_rate:0,version:null},buying_prices:[],prices:[{customer_tier:'retail',price_type:'package',price:200,mrp:null,effective_from:'2026-01-01'}],valuation:pool,weeks:[]};
 else if(name==='price_books')data=[{tenant_id:tenant,item_id:id(4),customer_tier:'retail',price_type:'package',price:200,effective_from:'2026-01-01'}];
 else if(name==='customers')data=[{customer_id:id(10),tenant_id:tenant,name:'Fixture buyer',phone:'01700000595',tier:'retail',shop_name:null,address:null}];
 else if(name==='adjust_inventory')data={movement_id:id(12)};
 else if(name==='get_business_catalogs')data={roles:[],weights:[{size_kg:12,active:true}]};
 else if(name==='list_lpg_brands')data=[{brand_id:id(51),brand_name:'Fixture LPG',is_active:true}];
 else if(name==='get_purchase_overview')data={total:0,created:0,in_transit:0,unpaid:0,outstanding:0};
 else if(name==='get_purchase_directory')data={total:0,entries:[]};
 else if(name==='get_financial_activity')data={total:0,entries:[]};
 else if(name==='get_sale_bottles')data={expected:0,received:0,outstanding:0,obligations:[],actual:[],events:[],event_count:0};
 else if(name==='receipt_printers')data=[];
 await route.fulfill({json:data});});
try {
 for(const width of [1440,768,390,320]){await page.setViewportSize({width,height:1050});await page.goto(base+'/#/finance',{waitUntil:'domcontentloaded',timeout:45000});await page.getByRole('heading',{name:'Income performance',exact:true}).waitFor();await page.getByRole('heading',{name:'Financial position trend',exact:true}).waitFor();assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`Finance overflow at ${width}`);await page.screenshot({path:`.temp/unified-accounting/fixture-finance-${width}.png`,fullPage:true});}
 for(const width of [320,390,768]){await page.setViewportSize({width,height:1050});await page.getByRole('navigation',{name:'Finance',exact:true}).getByRole('button',{name:'Loans',exact:true}).click();await page.getByRole('heading',{name:'Loans',exact:true}).waitFor();assert.equal(await page.getByRole('navigation',{name:'Finance management'}).count(),0);assert(await page.locator('.page-content').evaluate(e=>e.scrollWidth<=e.clientWidth+1),`Loans clips at ${width}`);await page.getByRole('navigation',{name:'Finance',exact:true}).getByRole('button',{name:'Analysis',exact:true}).click();}
 for(const width of [1440,390,320]){
  await page.setViewportSize({width,height:1050});
  const cards=page.locator('.overview-summary:visible');
  for(let i=0;i<await cards.count();i++){
   await cards.nth(i).click();const dialog=page.getByRole('dialog').last();await dialog.getByText('Recorded component 1',{exact:true}).waitFor();
   assert(await dialog.evaluate(e=>e.scrollWidth<=e.clientWidth+1),`Breakdown clips at ${width}`);
   await dialog.getByRole('button',{name:'Historical activity',exact:true}).click();await dialog.getByText('Historical fixture activity',{exact:true}).first().waitFor();
   await dialog.getByRole('button',{name:'Close dialog',exact:true}).click();
  }
 }
 await page.locator('.overview-summary:visible').first().click();let breakdown=page.getByRole('dialog').last();await breakdown.getByText('Recorded component 1',{exact:true}).waitFor();await breakdown.getByRole('button',{name:'Next page',exact:true}).click();await breakdown.getByText('Recorded component 21',{exact:true}).waitFor();await breakdown.getByRole('button',{name:'Historical activity',exact:true}).click();await breakdown.getByText('Journal evidence',{exact:true}).first().click();await breakdown.getByRole('columnheader',{name:'Debit',exact:true}).waitFor();await page.screenshot({path:'.temp/unified-accounting/fixture-breakdown-320.png',fullPage:true});await breakdown.getByRole('button',{name:'Close dialog',exact:true}).click();
 await page.setViewportSize({width:1440,height:1050});await page.getByRole('heading',{name:'Closing position',exact:true}).waitFor();await page.getByText('Advanced journal audit',{exact:true}).click();await page.getByText('Recorded fixture journal',{exact:true}).click();await page.getByRole('columnheader',{name:'Debit',exact:true}).waitFor();
 const download=page.waitForEvent('download');await page.getByRole('button',{name:'Export PDF',exact:true}).click();await(await download).saveAs('.temp/unified-accounting/fixture-report.pdf');
 await page.goto(base+'/#/inventory',{waitUntil:'domcontentloaded',timeout:45000});await page.getByRole('button',{name:'Add Item',exact:true}).click();let productDialog=page.getByRole('dialog').last();await productDialog.getByLabel('Brand *',{exact:true}).selectOption(id(51));await productDialog.getByLabel('Cylinder Weight (KG) *',{exact:true}).selectOption('12');await productDialog.getByLabel('Upload product photo',{exact:true}).setInputFiles('public/icons/app-192.png');await productDialog.getByRole('button',{name:'Create Item',exact:true}).click();await productDialog.waitFor({state:'hidden'});assert(calls.some(c=>c.name==='items'&&c.args.image_url?.endsWith('.webp')),'LPG product did not save its optimized Storage reference');await page.getByRole('button',{name:'Add Item',exact:true}).click();productDialog=page.getByRole('dialog').last();await productDialog.getByRole('button',{name:'Add product photo',exact:true}).waitFor();assert.equal(await productDialog.locator('.product-photo-preview').count(),0);await productDialog.getByRole('button',{name:'Cancel',exact:true}).click();
 await page.goto(base+'/#/inventory',{waitUntil:'domcontentloaded',timeout:45000});await page.getByRole('button',{name:'Stove Business',exact:true}).click();await page.getByRole('button',{name:/Fixture double stove/}).waitFor();await page.getByRole('button',{name:'Adjustment',exact:true}).click();let dialog=page.getByRole('dialog').last();await dialog.getByLabel('Product',{exact:true}).selectOption(stove.item_id);await dialog.getByLabel('Quantity',{exact:true}).fill('2');await dialog.getByLabel('Unit cost (Tk)',{exact:true}).fill('25.50');await dialog.getByLabel('Description',{exact:true}).fill('Valued fixture adjustment');await dialog.getByRole('button',{name:'Review adjustment',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Record adjustment',exact:true}).click();await page.waitForFunction(()=>document.querySelectorAll('dialog[open]').length===0);const adjustment=calls.find(x=>x.name==='adjust_inventory');assert.equal(adjustment.args.p_payload.filled_unit_cost,25.5);
 await page.goto(base+'/#/pos',{waitUntil:'domcontentloaded',timeout:45000});await page.getByRole('button',{name:'Stove Business',exact:true}).click();await page.getByRole('button',{name:/Fixture double stove/}).click();await page.getByPlaceholder('Phone, name, shop, address...').fill('01700000595');await page.getByText('Fixture buyer',{exact:true}).click();await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();dialog=page.getByRole('dialog').last();await dialog.getByText('Fixture double stove',{exact:true}).waitFor();assert.equal(await dialog.getByRole('button',{name:/Received bottles/}).count(),0);await page.screenshot({path:'.temp/unified-accounting/fixture-stove-checkout.png',fullPage:true});await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 assert.deepEqual(errors,[]);console.log('PASS: intercepted responsive accounting sections, journal/PDF, decimal valued adjustment and shared stove POS confirmation without LPG bottle controls');
} catch(error) { await page.screenshot({path:'.temp/unified-accounting/fixture-failure.png',fullPage:true}); console.error((await page.locator('body').innerText()).slice(0,4000),errors,calls.map(c=>c.name).slice(-20));throw error;} finally {await browser.close();}

