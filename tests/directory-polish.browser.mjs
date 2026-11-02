// Intercepted layout acceptance; all requests are fixtures, with no live writes.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { chromium } from 'playwright';
const base=process.env.LPG_BROWSER_BASE ?? 'http://127.0.0.1:5173';
const folder='.temp/directory-polish';mkdirSync(folder,{recursive:true});
const browser=await chromium.launch({channel:'chrome',headless:true});
const errors=[],results=[];
try {
 if(!process.argv.includes('--skip-batch')){const batch=await browser.newPage();await batch.goto(base);
 console.log(await (0,eval)('('+readFileSync('tests/batched-directory.browser.cjs','utf8')+')')(batch));await batch.close();}
 for(const theme of ['light','dark'])for(const width of [1440,375,320]){
  const ctx=await browser.newContext({viewport:{width,height:900},colorScheme:theme,reducedMotion:'reduce'});
  const p=await ctx.newPage();p.on('pageerror',e=>errors.push(e.message));
  const id=n=>`dd000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
  const user={id:id(1),aud:'authenticated',role:'authenticated',email:'directory@example.invalid',app_metadata:{},user_metadata:{},created_at:'2026-01-01T00:00:00Z'};
  const token='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'+Buffer.from(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).toString('base64url')+'.Zml4dHVyZQ';
  await ctx.addInitScript(({user,token})=>{for(const host of ['api.lpg.144.79.249.4.sslip.io','127.0.0.1:54321','localhost:54321','127.0.0.1:55421'])localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify({access_token:token,refresh_token:'fixture',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user}));},{user,token});
  const sales=Array.from({length:4},(_,n)=>({sale_id:id(10+n),customer_id:id(2),status:'completed',business_category:n%2?'stove':'lpg',created_at:'2026-11-01T08:00:00Z',sale_tier:'retail',name:'Directory customer',phone:'01712345678',shop_name:null,original_total:2400,total_amount:2400,paid_amount:1000,due:1400,additional_charges:0,expected:n%2?0:2,received_bottles:0,outstanding_bottles:n%2?0:2,items:[{item_id:id(30),type:'package',quantity:2,name:n%2?'Double burner stove with a long product name':'Brand 12kg 22mm'}]}));
  const purchases=sales.map((s,n)=>({purchase_id:id(40+n),business_category:s.business_category,company_name:n%2?null:'Supplier',supplier_name:n%2?'Stove supplier':null,plant_name:'Dhaka plant',status:'received',payment_status:'partial',created_at:s.created_at,total_cost:2400,payable_amount:2400,paid_amount:1000,vehicle_name:n%2?null:'Delivery truck',items:[{purchase_item_id:id(50+n),quantity:2,received_quantity:2,type:'package',product_name:n%2?'Double burner stove':'12 kg 22mm new cylinders'}]}));
  const calls=[];
  await p.exposeFunction('latestDirectorySort',rpc=>calls.findLast(c=>c.name===rpc)?.args.p_filters.sort);
  await p.route('**/auth/v1/**',r=>r.fulfill({json:user}));
  await p.route('**/rest/v1/**',async r=>{
   const req=r.request(),url=new URL(req.url()),name=url.pathname.split('/').pop(),args=req.method()==='POST'?req.postDataJSON():{};calls.push({name,args});let data=[];
   if(name==='user_profiles')data=[{tenant_id:id(3),full_name:'Fixture owner',email:user.email,tenants:{business_name:'Directory layout fixtures'}}];
   else if(name==='get_my_preferences')data={theme:null};
   else if(name==='get_my_permissions')data=['sales:view','purchases:view','purchases:manage','employees:view','customers:view','finance:manage','receipts:print'];
   else if(name==='get_sales_directory'||name==='get_purchase_directory'){const category=args.p_filters.business_category;const rows=(name==='get_sales_directory'?sales:purchases).filter(s=>!category||category==='all'||s.business_category===category);data={entries:rows,total:rows.length};}
   else if(name==='get_sales_overview')data={total:4,amount:9600,due:5600,bottles:4};
   else if(name==='get_purchase_overview')data={total:4,created:0,in_transit:0,unpaid:4,outstanding:5600};
   else if(name==='get_employee_overview')data={employees:1,active:1,types:['Driver']};
   else if(name==='get_employee_directory')data={total:1,entries:[{employee_id:id(60),name:'Fixture employee',employee_type_name:'Driver',business_unit:'gas_business',is_active:true,primary_phone:'01712345678'}]};
   else if(name==='get_employee_presence')data={timezone:'Asia/Dhaka',entries:[]};
   else if(name==='can_cancel_purchases')data=true;
   else if(name==='sales'){const s=sales.find(s=>url.searchParams.get('sale_id')==='eq.'+s.sale_id)??sales[1];data={...s,subtotal:2400,discount_amount:0,exchange_fee:0,notes:null,customers:{name:s.name,phone:s.phone},user_profiles:{full_name:'Fixture owner'},sale_items:[{item_id:id(30),type:'package',quantity:2,unit_price:1200,line_total:2400,items:{product_name:s.items[0].name,size_kg:0,image_url:null}}]};}
   else if(name==='get_sale_settlement')data={status:'completed',total:2400,paid:1000,due:1400,payment_count:0,payments:[]};
   else if(name==='get_sale_bottles')data={expected:0,received:0,outstanding:0,obligations:[],actual:[],events:[],event_count:0};
   return r.fulfill({json:data});
  });
  const settle=async()=>{await p.waitForLoadState('networkidle');await p.waitForFunction(()=>!document.querySelector('[aria-busy="true"]'));await p.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);};
  const shot=async name=>{assert(await p.evaluate(()=>[document.documentElement,...document.querySelectorAll('.page-content,dialog[open]')].every(e=>e.scrollWidth<=e.clientWidth+1)),name+' horizontal overflow');await p.screenshot({path:`${folder}/${name}-${width}-${theme}.png`});};
  for(const route of ['sales','purchases','employees']){
   await p.goto(base+'/#/'+route);await p.locator(route==='employees'?'.employee-page':route==='sales'?'.sales-page':'.purchases-page:not(.sales-page)').waitFor();await settle();const root=p.locator(route==='employees'?'.employee-page':'.purchases-page');
   const sort=root.getByLabel('Sort by',{exact:true});const sortOptions=await sort.locator('option').evaluateAll(options=>options.map(o=>o.value));
   for(const option of sortOptions){await sort.selectOption(option);await settle();const dir=root.getByRole('button',{name:/Sort direction:/});await dir.click();const expected=await dir.getAttribute('aria-label')==='Sort direction: ascending'?option:option.replace(/_asc$/,'_desc');await p.waitForFunction(async({rpc,expected})=>await window.latestDirectorySort(rpc)===expected,{rpc:`get_${route==='purchases'?'purchase':route==='employees'?'employee':'sales'}_directory`,expected});await settle();}
   if(route!=='employees'){
    const filter=root.getByLabel('Business',{exact:true});for(const category of ['lpg','stove','all']){await filter.selectOption(category);await settle();assert.equal(await root.locator('.record-card').count(),category==='all'?4:2);}await shot(route);
    if(route==='sales'){await filter.selectOption('stove');await settle();await root.locator('.record-card').first().click();await settle();const d=p.getByRole('dialog');assert.equal(await d.getByText('Exchange cost',{exact:true}).count(),0);assert.equal(await d.getByText('Stove product',{exact:true}).count(),1);assert(!/refills|packages|filled out/i.test(await d.innerText()));await shot('stove-sale-modal');await p.keyboard.press('Escape');}
    else {await root.getByRole('button',{name:'New Purchase',exact:true}).click();await p.getByRole('dialog',{name:'New purchase',exact:true}).waitFor();await shot('purchase-business-choice');await p.keyboard.press('Escape');}
   }else await shot(route);
  }
  results.push({width,theme,passed:true});await ctx.close();
 }
 assert.deepEqual(errors,[]);writeFileSync(folder+'/results.json',JSON.stringify(results,null,2));console.log('PASS compact cards, batch pagination, all sort controls, business filters, stove modal and purchase business choice at 1440/375/320 in light/dark');
}finally{await browser.close();}
