// Isolated intercepted API fixtures. A committed response is deliberately lost.
async page => {
 const origin = new URL(page.url()).origin; const id = n => `bc000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
 const tenant=id(1),sid=id(2),sku=id(3),other=id(4),uid=id(5);
 const user={id:uid,aud:'authenticated',role:'authenticated',email:'bottles@example.invalid',app_metadata:{},user_metadata:{}};
 const token='eyJhbGciOiJIUzI1NiJ9.'+btoa(JSON.stringify({sub:uid,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','')+'.Zml4dHVyZQ';
 await page.context().addInitScript(({user,token,tenant})=>{
  const session={access_token:token,refresh_token:'fixture',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,token_type:'bearer',user};
  for(const host of ['api.lpg.144.79.249.4.sslip.io','127.0.0.1:54321','localhost:54321','127.0.0.1:55421'])localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify(session));
  localStorage.setItem(`lpg:receipt-print-method:v1:${tenant}`,'browser');window.print=()=>{throw Error('Unexpected printing');};
 },{user,token,tenant});
 const customer={customer_id:id(9),tenant_id:tenant,name:'Bottle fixture customer',phone:'01700000000',tier:'retail'};
 const products=[{item_id:sku,brand_id:id(20),size_kg:12,mouth_size:'22mm',filled_quantity:50,empty_quantity:10,lpg_brands:{brand_id:id(20),brand_name:'Bashundhara'}},{item_id:other,brand_id:id(21),size_kg:12,mouth_size:'22mm',filled_quantity:50,empty_quantity:10,lpg_brands:{brand_id:id(21),brand_name:'Jamuna'}}];
 const wallets=[{wallet_id:id(10),name:'Cash Register',type:'cash',kind:'cash',balance:0,is_active:true}];
 const sale={sale_id:sid,sale_tier:'retail',created_at:'2026-10-23T06:00:00Z',subtotal:500,total_amount:500,discount_amount:0,exchange_fee:0,customers:customer,user_profiles:{full_name:'Fixture operator'},sale_items:[{quantity:5,type:'refill',unit_price:100,line_total:500,items:products[0]},{quantity:5,type:'empty_return',unit_price:0,line_total:0,items:products[0]}]};
 let received=2,cost=0,paid=0,lost=false,loseFinalBottle=false,losePayment=true;const calls=[],operations=new Map(),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));
 await page.route('**/rest/v1/**',async route=>{
  const req=route.request(),url=new URL(req.url()),name=url.pathname.split('/').pop(),a=req.method()==='POST'?req.postDataJSON():{};calls.push({name,a});let data=[];
  if(name==='user_profiles')data=[{tenant_id:tenant,email:user.email,full_name:'Owner',tenants:{business_name:'Bottle fixtures'}}];
  else if(name==='get_my_permissions')data=['sales:view','sales:collect_bottles','pos:sell','dashboard:view','receipts:print','finance:manage','finance:view'];
  else if(name==='items')data=products;
  else if(name==='customers')data=[customer];
  else if(name==='price_books')data=[{item_id:sku,customer_tier:'retail',price_type:'refill',price:100,effective_from:'2026-01-01'}];
  else if(name==='create_pos_sale')data={sale_id:id(70),sale_tier:'retail',customer_id:customer.customer_id,subtotal:100,total_amount:100,paid_amount:100,due:0,customer_phone:customer.phone,customer_name:customer.name};
  else if(name==='wallets'||name==='get_payment_wallets')data=wallets;
  else if(name==='receipt_printers')data=null;
  else if(name==='sales')data=sale;
  else if(name==='get_sales_overview')data={total:31,amount:15500,due:500-paid,bottles:5-received};
  else if(name==='get_sales_directory')data={total:31,entries:Array.from({length:Math.min(a.p_limit,31-a.p_offset)},(_,n)=>({sale_id:n+a.p_offset===0?sid:id(100+n+a.p_offset),created_at:sale.created_at,sale_tier:'retail',name:customer.name,phone:customer.phone,total_amount:500,additional_charges:0,paid_amount:paid,due:500-paid,expected:5,received_bottles:received,outstanding_bottles:5-received,items:[{item_id:sku,name:'Bashundhara 12kg 22mm',type:'refill',quantity:5}],bottle_dues:[{item_id:sku,name:'Bashundhara 12kg',quantity:5-received}]}))};
  else if(name==='get_sale_bottles')data={expected:5,received,outstanding:5-received,obligations:[{item_id:sku,name:'Bashundhara 12kg 22mm',size_kg:12,mouth_size:'22mm',expected:5,received,outstanding:5-received}],actual:[{item_id:sku,name:'Bashundhara 12kg',phase:'checkout',quantity:received-(received>=3?1:0)},...(received>=3?[{item_id:other,name:'Jamuna 12kg',phase:'collection',quantity:1}]:[])],event_count:1,events:[{id:id(30),kind:'bottles',phase:'checkout',created_at:sale.created_at,actor:'Fixture operator',amount:0,note:'Three bottles due later',lines:[]}]};
  else if(name==='get_sale_settlement')data={total:500+cost,original_total:500,additional_charges:cost,paid,due:500+cost-paid,paid_at_checkout:0,payment_count:0,payments:[],receipt_payments:[],checkout_payments:[]};
  else if(name==='get_sale_receipt')data={sale,shop_name:'Current receipt business',brands:[],settlement:{total:500+cost,original_total:500,additional_charges:cost,paid,due:500+cost-paid,receipt_payments:[]},bottles:{expected:5,received,outstanding:Math.max(0,5-received),obligations:[],actual:[{item_id:sku,name:'Bashundhara 12kg',phase:'checkout',quantity:2},...(received>2?[{item_id:other,name:'Jamuna 12kg',phase:'collection',quantity:received-2}]:[])]}};
  else if(name==='collect_sale_bottles'){
   if(!operations.has(a.p_request_id)){received+=a.p_payload.lines.reduce((s,l)=>s+l.quantity,0);cost+=a.p_payload.fee;operations.set(a.p_request_id,a);}
   if(!lost || loseFinalBottle){lost=true;loseFinalBottle=false;return route.abort('connectionreset');}data={sale_id:sid};
  }
  else if(name==='collect_sale_payment'){
   if(!operations.has(a.p_request_id)){paid+=a.p_payments.reduce((s,p)=>s+p.amount,0);operations.set(a.p_request_id,a);}
   if(losePayment){losePayment=false;return route.abort('connectionreset');}data={sale_id:sid};
  }
  await route.fulfill({json:data});
 });
 const check=(v,m)=>{if(!v)throw Error(m);};
 await page.goto(origin+'/?bottle-fixtures=1#/sales');await page.locator('.sale-card').first().waitFor();
 await page.getByLabel('Money status',{exact:true}).selectOption('partial');await page.getByLabel('Bottle status',{exact:true}).selectOption('outstanding');await page.getByLabel('Search sales',{exact:false}).fill('Bashundhara, Jamuna');
 await page.waitForFunction(()=>document.querySelector('.sales-grid')?.getAttribute('aria-busy')==='false');
 for(const width of [320,390,768,1440]){await page.setViewportSize({width,height:950});await page.locator('.sale-card').first().waitFor();check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Sales overflow ${width}`);
  check(await page.locator('.purchases-header').evaluate(header=>{
   const action=header.querySelector('.purchases-header-actions').getBoundingClientRect();
   return [...header.querySelectorAll('dd')].every(value=>{
    const range=document.createRange();range.selectNodeContents(value);const amount=range.getBoundingClientRect();
    return amount.right<=action.left||amount.left>=action.right||amount.bottom<=action.top||amount.top>=action.bottom;
   });
  }),`New sale obscures overview amount at ${width}`);
  await page.screenshot({path:`.temp/bottles-sales-${width}.png`,fullPage:true});}
 check(calls.some(c=>c.name==='get_sales_directory'&&c.a.p_filters.bottles==='outstanding'&&c.a.p_filters.payment==='partial'),'Combined server filters missing');
 await page.locator('.sale-card').first().click();const detail=page.getByRole('dialog',{name:/Transaction #/});
 await detail.getByRole('button',{name:'Print receipt',exact:true}).click();
 const printDialog=page.getByRole('dialog',{name:'Print receipt',exact:true});await printDialog.getByLabel('80mm receipt preview').waitFor();
 check(await printDialog.getByRole('heading',{name:/^(Payments|Bottle settlement|Transaction history)$/}).count()===0,'Print dialog contains settlement panels');
 await printDialog.getByRole('button',{name:'Close',exact:true}).click();check(await detail.isVisible(),'Printing modal lost parent sale');
 await detail.getByRole('button',{name:'Collect bottles',exact:true}).click();
 const collect=page.getByRole('dialog',{name:'Collect bottles',exact:true});
 check(await collect.getByRole('button',{name:'Record bottle collection',exact:true}).isDisabled(),'Zero collection allowed');
 await collect.getByLabel('Received quantity for Jamuna 12kg 22mm',{exact:true}).fill('1');await collect.getByRole('checkbox',{name:/I accept/}).check();
 await collect.getByLabel('Received quantity for Bashundhara 12kg 22mm',{exact:true}).fill('1');check(await collect.getByLabel('Received quantity for Jamuna 12kg 22mm',{exact:true}).inputValue()==='1','Independent product quantities changed');await collect.getByRole('button',{name:'Remove Bashundhara 12kg 22mm',exact:true}).click();
 await collect.getByLabel('Additional Settlement Cost (Tk, optional)',{exact:true}).fill('20');check(await collect.getByLabel('Expense wallet',{exact:true}).count()===0,'Expense wallet still shown');
 await page.setViewportSize({width:320,height:800});check(await collect.evaluate(e=>e.scrollWidth<=e.clientWidth),'Collection dialog overflow');await page.screenshot({path:'.temp/bottles-collection-320.png'});
 await collect.getByRole('button',{name:'Record bottle collection',exact:true}).click();await collect.getByRole('button',{name:'Recover bottle collection',exact:true}).waitFor();
 await page.reload();await page.getByRole('button',{name:'Recover bottle collection',exact:true}).click();await page.getByText('Previous bottle collection confirmed',{exact:true}).waitFor();
 const collections=calls.filter(c=>c.name==='collect_sale_bottles');check(collections.length===2&&collections[0].a.p_request_id===collections[1].a.p_request_id,'Recovery changed request ID');check(received===3&&cost===20,'Collection posted twice');
 await page.locator('.sale-card').first().click();await detail.getByRole('button',{name:'Collect bottles',exact:true}).click();
 await collect.getByLabel('Received quantity for Bashundhara 12kg 22mm',{exact:true}).fill('1');await collect.getByRole('button',{name:'Record bottle collection',exact:true}).click();await collect.waitFor({state:'hidden'});
 check(await detail.isVisible(),'Parent detail closed after settlement');await detail.locator('.bottle-summary strong').nth(1).filter({hasText:'4'}).waitFor();await detail.getByText('Unexpected product',{exact:true}).waitFor();
 // A committed final collection can clear the balance before its response arrives.
 // Closing its failed editor must retain recovery inside the same parent detail.
 loseFinalBottle=true;
 await detail.getByRole('button',{name:'Collect bottles',exact:true}).click();
 await collect.getByLabel('Received quantity for Bashundhara 12kg 22mm',{exact:true}).fill('1');
 await collect.getByRole('button',{name:'Record bottle collection',exact:true}).click();await collect.getByRole('button',{name:'Recover bottle collection',exact:true}).waitFor();
 await collect.getByRole('button',{name:'Cancel',exact:true}).click();
 await detail.getByRole('button',{name:'Recover bottle collection',exact:true}).click();
 await collect.getByRole('button',{name:'Recover bottle collection',exact:true}).click();await collect.waitFor({state:'hidden'});
 await detail.getByText('Bottle settled.',{exact:false}).waitFor();check(await detail.getByRole('button',{name:'Collect bottles',exact:true}).isDisabled(),'Settled collection still enabled');
 check(received===5,'Final bottle recovery posted stock twice');
 await detail.getByRole('button',{name:'Print receipt',exact:true}).click();
 for(const width of ['58','80']){
  await printDialog.getByLabel('Browser receipt width',{exact:true}).selectOption(width);
  const preview=printDialog.getByLabel(`${width}mm receipt preview`);await preview.waitFor();const content=await preview.innerText();
  check(content.includes('Expected 5 | Received 2')&&content.includes('Expected 0 | Received 3')&&content.includes('Bottle Settled'),'Reopened receipt did not refresh bottle state');
  check(content.includes('Additional Settlement Cost')&&content.includes('520.00'),'Reopened receipt did not refresh customer cost');
 }
 await printDialog.getByRole('button',{name:'Close',exact:true}).click();
 await detail.getByRole('button',{name:'Collect payment',exact:true}).click();const money=page.getByRole('dialog',{name:/Collect payment ·/});
 await money.getByRole('button',{name:/Pay remaining/}).click();await money.getByRole('button',{name:'Record payment',exact:true}).click();await money.getByRole('button',{name:'Recover transaction',exact:true}).waitFor();
 await money.getByRole('button',{name:'Cancel',exact:true}).click();
 await page.reload();await page.locator('.sale-card').first().click();await detail.getByText('Fully paid',{exact:true}).waitFor();
 await detail.getByRole('button',{name:'Recover payment',exact:true}).click();
 await money.getByRole('button',{name:'Recover transaction',exact:true}).click();await money.waitFor({state:'hidden'});
 const moneyCalls=calls.filter(c=>c.name==='collect_sale_payment');check(moneyCalls.length===2&&moneyCalls[0].a.p_request_id===moneyCalls[1].a.p_request_id&&paid===520,'Final payment recovery posted money twice');
 await detail.getByRole('button',{name:'Back to Sales',exact:true}).click();await page.getByRole('link',{name:'New sale',exact:true}).click();
 await page.getByRole('button',{name:'Refill for Bashundhara 12kg',exact:true}).click();
 await page.getByRole('button',{name:'Return Empty for Bashundhara 12kg',exact:true}).click();
 await page.getByPlaceholder('Phone, name, shop, address...').fill(customer.phone);await page.getByText(customer.name,{exact:true}).click();
 await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();const checkout=page.getByRole('dialog',{name:'Confirm Sale',exact:true});
 check(await checkout.getByRole('button',{name:/Received bottles/}).getAttribute('aria-expanded')==='false','Checkout bottles not collapsed');await checkout.getByRole('button',{name:/Received bottles/}).click();
 check(await checkout.getByLabel('Received quantity 1',{exact:true}).inputValue()==='1','Checkout receipt did not default to expected');await checkout.getByRole('button',{name:/Decrease Bashundhara/}).click();await checkout.getByRole('button',{name:/Increase Bashundhara/}).click();check(await checkout.getByRole('button',{name:/Increase Bashundhara/}).isEnabled(),'Overreceipt stepper is capped');await checkout.getByLabel('Received quantity 1',{exact:true}).fill('0');
 check(await checkout.getByRole('button',{name:'Confirm',exact:true}).isEnabled(),'Optional bottle note blocks checkout');
 await checkout.getByLabel('Bottle note (optional)',{exact:true}).fill('All bottles remain with customer');
 for(const width of [320,768,1440]){await page.setViewportSize({width,height:900});check(await checkout.evaluate(e=>e.scrollWidth<=e.clientWidth),`Checkout overflow ${width}`);}
 await checkout.getByRole('button',{name:'Confirm',exact:true}).click();await checkout.waitFor({state:'hidden'});
 const created=calls.find(c=>c.name==='create_pos_sale');check(created.a.p_bottles.lines.length===0&&created.a.p_bottles.note==='All bottles remain with customer','Checkout lost separate physical receipt');
 check(created.a.p_items.find(l=>l.type==='empty_return').quantity===1,'Checkout rewrote expected returns');check(errors.length===0,errors.join(';'));
 return {responsive:[320,390,768,1440],recovery:'same request once',parent:'retained',errors};
}

