// Intercepted APIs: catalog pagination, independent products, checkout and receipt layouts.
async page => {
 const origin = new URL(page.url()).origin, id = n => `bd000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
 const tenant=id(1), uid=id(2), sid=id(3);
 const user={id:uid,aud:'authenticated',role:'authenticated',email:'layout@example.invalid',app_metadata:{},user_metadata:{}};
 const token='eyJhbGciOiJIUzI1NiJ9.'+btoa(JSON.stringify({sub:uid,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','')+'.Zml4dHVyZQ';
 await page.context().addInitScript(({user,token,tenant})=>{
  const session={access_token:token,refresh_token:'fixture',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,token_type:'bearer',user};
  for(const host of ['api.lpg.144.79.249.4.sslip.io','127.0.0.1:54321','localhost:54321','127.0.0.1:55421'])localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify(session));
  localStorage.setItem(`lpg:receipt-print-method:v1:${tenant}`,'browser');
  window.print=()=>{throw Error('Unexpected printing');};
 },{user,token,tenant});
 // Settings order deliberately differs from alphabetical order.
 const brands=['Zeta','Alpha','Middle'].map((brand_name,index)=>({brand_id:id(10+index),brand_name,is_active:true}));
 const products=brands.flatMap(brand=>Array.from({length:[3,11,16][brands.indexOf(brand)]},(_,index)=>({item_id:id(100+brands.indexOf(brand)*20+index),brand_id:brand.brand_id,brand:brand.brand_name,lpg_brands:brand,size_kg:[5,12,25,35,45,50,60,65][Math.floor(index/2)],mouth_size:index%2?'22mm':'20mm',filled_quantity:100,empty_quantity:100})));
 const customer={customer_id:id(4),tenant_id:tenant,name:'Layout customer',phone:'01700000000',tier:'retail'};
 const cash={wallet_id:id(5),name:'Cash Register',type:'cash',kind:'cash',balance:1000,is_active:true};
 const expected=products[0], actual=products[10], later=products[11];
 const obligations=[{item_id:expected.item_id,name:'Zeta 5kg 20mm',size_kg:5,mouth_size:'20mm',expected:5,received:0,difference:-5}];
 const bottles={expected:5,received:2,outstanding:3,obligations,actual:[{item_id:actual.item_id,name:'Alpha 5kg 20mm',phase:'checkout',quantity:1},{item_id:later.item_id,name:'Alpha 5kg 22mm',phase:'collection',quantity:1}],event_count:0,events:[]};
 const sale={sale_id:sid,sale_tier:'retail',created_at:'2026-10-24T06:00:00Z',subtotal:300,total_amount:300,discount_amount:0,exchange_fee:0,customers:customer,sale_items:[{item_id:expected.item_id,type:'empty_return',quantity:5,unit_price:0,line_total:0,items:expected},{item_id:products[10].item_id,type:'refill',quantity:1,unit_price:100,line_total:100,items:products[10]},{item_id:expected.item_id,type:'package',quantity:1,unit_price:200,line_total:200,items:expected}]};
 const settlement={total:300,original_total:300,additional_charges:0,paid:300,due:0,paid_at_checkout:300,payment_count:0,payments:[],receipt_payments:[{wallet_name:'Cash Register',method:'cash',amount:300}],checkout_payments:[]};
 const errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.route('**/auth/v1/**',route=>route.fulfill({json:user}));
 await page.route('**/rest/v1/**',async route=>{
  const name=new URL(route.request().url()).pathname.split('/').pop();let data=[];
  if(name==='user_profiles')data=[{tenant_id:tenant,email:user.email,full_name:'Owner',tenants:{business_name:'Layout fixtures'}}];
  else if(name==='get_my_permissions')data=['sales:view','sales:collect_bottles','pos:sell','receipts:print','finance:manage','finance:view'];
  else if(name==='items')data=products;
  else if(name==='list_lpg_brands')data=brands;
  else if(name==='customers')data=[customer];
  else if(name==='get_customer_bottle_balance')data=0;
  else if(name==='price_books')data=products.flatMap(product=>['package','refill'].map(price_type=>({item_id:product.item_id,price_type,customer_tier:'retail',price:price_type==='package'?200:100,effective_from:'2026-01-01'})));
  else if(name==='get_payment_wallets'||name==='wallets')data=[cash];
  else if(name==='receipt_printers')data=null;
  else if(name==='sales')data=sale;
  else if(name==='get_sale_bottles')data=bottles;
  else if(name==='get_sale_settlement')data=settlement;
  else if(name==='get_sale_receipt')data={sale,settlement,bottles,brands,shop_name:'Layout fixtures'};
  else if(name==='get_sales_overview')data={total:1,amount:300,due:0,bottles:3};
  else if(name==='get_sales_directory')data={total:1,entries:[{...sale,name:customer.name,phone:customer.phone,original_total:300,paid_amount:300,due:0,additional_charges:0,expected:5,received_bottles:2,outstanding_bottles:3,items:[]}]};
  await route.fulfill({json:data});
 });
 const check=(value,message)=>{if(!value)throw Error(message);};
 const fits=async(dialog,label)=>{
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  check(await dialog.evaluate(element=>{
  const body=element.querySelector('.modal-body'), footer=element.querySelector('.modal-footer');
  const dialogBox=element.getBoundingClientRect(), footerBox=footer.getBoundingClientRect();
  return element.scrollWidth<=element.clientWidth && body.scrollWidth<=body.clientWidth && dialogBox.top>=0 && dialogBox.bottom<=innerHeight && footerBox.bottom<=dialogBox.bottom && footerBox.top>=dialogBox.top;
 }),label);
 };
 await page.setViewportSize({width:1440,height:950});
 await page.goto(origin+'/?bottle-layouts='+Date.now()+'#/sales');await page.locator('.sale-card').first().click();
 const detail=page.getByRole('dialog',{name:/Transaction #/});
 const left=detail.getByRole('region',{name:'Expected bottles',exact:true}),right=detail.getByRole('region',{name:'Received bottles',exact:true});
 await left.getByRole('listitem').first().waitFor();await right.getByRole('listitem').first().waitFor();
 check(await left.getByRole('listitem').count()===1,'Expected products were padded with actual products');
 check(await right.getByRole('listitem').count()===2,'Received products were merged into expectations');
 check((await right.innerText()).includes('collected later'),'Later receipt source missing');
 await detail.getByRole('button',{name:'Collect bottles',exact:true}).click();
 const collect=page.getByRole('dialog',{name:'Collect bottles',exact:true});
 await collect.getByLabel('Received quantity for Zeta 5kg 20mm',{exact:true}).waitFor();
 check(await collect.locator('.bottle-picker-brand').first().innerText()==='Zeta','Configured brand order ignored');
 const layout = await collect.locator('.bottle-picker-grid').evaluate(el => ({columns:getComputedStyle(el).gridTemplateColumns.split(/\s+/).length,rows:Math.max(2, Math.min(4, Math.floor((innerHeight - 320) / 110)))}));
 let used=0,firstPageCount=0;
 for(const [index,product] of products.entries()){
  if(index&&product.brand_id!==products[index-1].brand_id&&used%layout.columns)used+=layout.columns-used%layout.columns;
  if(used>=layout.columns*layout.rows)break;
  used++;firstPageCount++;
 }
 await page.waitForFunction(count => document.querySelectorAll('.bottle-picker-card').length === count, firstPageCount);
 const separateRows=await collect.locator('.bottle-picker-grid').evaluate(el=>el.children[3].getBoundingClientRect().top>el.children[0].getBoundingClientRect().top&&Math.abs(el.children[3].getBoundingClientRect().left-el.children[0].getBoundingClientRect().left)<1);
 check(separateRows,'Every brand must begin on a new row in configured order');
 await collect.getByRole('button',{name:'Next page',exact:true}).click();
 const anchorLabel=await collect.locator('.bottle-picker-card input').first().getAttribute('aria-label');
 await page.setViewportSize({width:390,height:844});
 await page.waitForFunction(()=>document.querySelectorAll('.bottle-picker-card').length===8);
 check(await collect.getByLabel(anchorLabel,{exact:true}).count()===1,'Picker resize lost its record anchor');
 await page.setViewportSize({width:1440,height:950});
  await page.waitForFunction(count=>document.querySelectorAll('.bottle-picker-card').length===count,products.length-firstPageCount);
 check(await collect.locator('.bottle-picker-card input').first().getAttribute('aria-label')===anchorLabel,'Picker resize round trip drifted');
 await collect.getByRole('button',{name:'Page 1',exact:true}).click();
 await collect.getByLabel('Received quantity for Zeta 5kg 20mm',{exact:true}).fill('1');
 await collect.getByLabel('Find bottles',{exact:true}).fill('Middle 5kg 20mm');
 await collect.getByLabel('Received quantity for Middle 5kg 20mm',{exact:true}).fill('1');
 await collect.getByRole('checkbox',{name:/I accept Middle/}).check();
 await collect.getByLabel('Find bottles',{exact:true}).fill('Zeta 5 20mm');
 check(await collect.locator('.bottle-picker-card').count()===1,'Brand/weight/mouth search incorrect');
 check(await collect.getByLabel('Received quantity for Zeta 5kg 20mm',{exact:true}).inputValue()==='1','Pagination lost selection');
 check(await collect.getByRole('checkbox',{name:/I accept Middle/}).isChecked(),'Search lost acknowledgement');
 await collect.getByLabel('Received quantity for Zeta 5kg 20mm',{exact:true}).fill('3');
 check(await collect.getByRole('button',{name:'Record bottle collection',exact:true}).isEnabled(),'Acknowledged physical overreceipt blocked');
 await collect.getByRole('button',{name:'Decrease Zeta 5kg 20mm',exact:true}).click();
 check(await collect.getByRole('button',{name:'Increase Zeta 5kg 20mm',exact:true}).isEnabled(),'Overreceipt is capped');
 check(await collect.getByRole('button',{name:'Record bottle collection',exact:true}).isEnabled(),'Acknowledged valid selection blocked');
 await collect.getByLabel('Find bottles',{exact:true}).fill('');
 const firstPage=collect.getByRole('navigation',{name:'products pages'}).getByRole('button',{name:'Page 1',exact:true});
 if(await firstPage.count())await firstPage.click();
 for(const [width,height] of [[1440,950],[1024,768],[768,900],[390,844],[320,568]]){
  await page.setViewportSize({width,height});await fits(collect,`Collection layout ${width}`);
  if(width===320)check(await collect.locator('.bottle-picker-card').evaluateAll(cards=>Math.abs(cards[0].getBoundingClientRect().top-cards[1].getBoundingClientRect().top)<1),'Small phone should fit two compact bottles');
  await collect.locator('.modal-body').evaluate(element=>element.scrollTop=0);
  await page.screenshot({path:`.temp/bottle-grid-${width}.png`});
  await collect.locator('.modal-body').evaluate(element=>element.scrollTop=element.scrollHeight);
  await fits(collect,`Scrolled collection ${width}`);
 }
 await page.evaluate(()=>{document.documentElement.dataset.theme='dark';document.documentElement.style.colorScheme='dark';});
 await page.waitForFunction(()=>getComputedStyle(document.querySelector('.bottle-picker input')).backgroundColor==='rgb(18, 23, 32)');
 await collect.locator('.modal-body').evaluate(element=>element.scrollTop=0);
 await page.screenshot({path:'.temp/bottle-grid-dark-320.png'});
 await collect.getByLabel('Find bottles',{exact:true}).focus();await page.keyboard.press('Tab');
 check(await collect.evaluate(element=>element.contains(document.activeElement)),'Keyboard focus escaped collection');
 await page.evaluate(()=>{document.documentElement.dataset.theme='light';document.documentElement.style.colorScheme='light';});
 await collect.getByRole('button',{name:'Cancel',exact:true}).click();
 for(const width of [320,768,1440]){
  await page.setViewportSize({width,height:900});await fits(detail,`Details layout ${width}`);
  const columns=await detail.locator('.bottle-comparison').evaluate(element=>getComputedStyle(element).gridTemplateColumns.split(' ').length);
  check(columns===(width<600?1:2),`Settlement column count ${width}`);
  await detail.locator('.bottle-comparison').scrollIntoViewIfNeeded();await page.screenshot({path:`.temp/bottle-columns-${width}.png`});
 }
 await detail.getByRole('button',{name:'Print receipt',exact:true}).click();
 const print=page.getByRole('dialog',{name:'Print receipt',exact:true});
 for(const width of ['58','80']){
  await print.getByLabel('Browser receipt width',{exact:true}).selectOption(width);
  const preview=print.getByLabel(`${width}mm receipt preview`);await preview.waitFor();
  const text=await preview.innerText();check(text.includes('Expected 5 | Received 0'),'Substituted checkout bottles attributed to expected product');
  check(!/Free|BOTTLE SETTLEMENT|Collected later:/.test(text),'Receipt contains removed sections');
  check(text.indexOf('New Package')<text.indexOf('Refill')&&text.indexOf('Refill')<text.indexOf('Expected 5'),'Saved receipt category order incorrect');
  await fits(print,`${width}mm receipt layout`);
 }
 await print.getByRole('button',{name:'Close',exact:true}).click();await detail.getByRole('button',{name:'Back to Sales',exact:true}).click();
 await page.goto(origin+'/?bottle-layouts=1#/pos');await page.setViewportSize({width:1440,height:950});
 // Add Alpha before Zeta, refills before packages.
 for(const name of ['Alpha','Zeta'])for(const type of ['Refill','New Package','Return Empty'])await page.getByRole('button',{name:`${type} for ${name} 5kg`,exact:true}).nth(0).click();
 const cartTypes=await page.locator('.pos-cart-line').allTextContents();
 check(cartTypes.length===6&&cartTypes[0].includes('Zeta')&&cartTypes[1].includes('Alpha')&&cartTypes[0].includes('package')&&cartTypes[2].includes('refill')&&cartTypes[4].includes('empty return'),'Cart presentation order incorrect');
 await page.getByPlaceholder('Phone, name, shop, address...').fill(customer.phone);await page.getByText(customer.name,{exact:true}).click();
 await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();
 const checkout=page.getByRole('dialog',{name:'Confirm Sale',exact:true}), toggle=checkout.getByRole('button',{name:/Received bottles/});
 await checkout.getByRole('button',{name:'Advanced payments',exact:true}).click();
 const amount=checkout.getByLabel('Payment 1 amount',{exact:true});
 check(await amount.evaluate(el=>getComputedStyle(el).textAlign)==='left','Payment input must edit from the left');
 await amount.fill('123.45');await amount.press('Home');await amount.press('ArrowRight');await amount.press('Delete');
 check(await amount.inputValue()==='13.45','Delete moved the cursor or reformatted the amount');
 await amount.press('Backspace');check(await amount.inputValue()==='3.45','Backspace did not remove the previous digit');
 await amount.press('Control+A');await amount.press('Backspace');check(await amount.inputValue()==='','Amount cannot be cleared naturally');
 await amount.pressSequentially('12.30');
 await amount.evaluate(el=>el.setSelectionRange(0,2));await amount.pressSequentially('9');
 check(await amount.inputValue()==='9.30','Selection replacement moved the cursor or changed decimals');
 await checkout.getByRole('button',{name:'Advanced payments',exact:true}).click();
 check(await toggle.getAttribute('aria-expanded')==='false','Bottles initially expanded');
 await toggle.click();await checkout.getByLabel('Received quantity 1',{exact:true}).fill('0');await toggle.click();
 check((await toggle.innerText()).includes('1 outstanding'),'Collapsed totals are stale');
 for(const width of [320,768,1440]){await page.setViewportSize({width,height:800});await fits(checkout,`Checkout ${width}`);}
 await checkout.getByRole('button',{name:'Cancel',exact:true}).click();await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();
 check(await page.getByRole('button',{name:/Received bottles/}).getAttribute('aria-expanded')==='false','Reopened checkout not collapsed');
 await checkout.getByRole('button',{name:'Cancel',exact:true}).click();
 bottles.obligations=products.map(product=>({item_id:product.item_id,name:`${product.brand} ${product.size_kg}kg ${product.mouth_size}`,size_kg:product.size_kg,mouth_size:product.mouth_size,expected:2,received:0,difference:2}));
 bottles.expected=60;bottles.outstanding=58;
 await page.goto(origin+'/?bottle-long-lists=1#/sales');await page.reload();await page.locator('.sale-card').first().click();
 await left.getByRole('listitem').nth(29).waitFor({state:'attached'});
 for(const width of [320,768,1440]){
  await page.setViewportSize({width,height:800});await fits(detail,`Long settlement lists ${width}`);
  check(await left.locator('ul').evaluate(element=>element.scrollHeight>element.clientHeight),'Long expected list is not scrollable');
  await left.getByRole('listitem').last().scrollIntoViewIfNeeded();
 }
 check(errors.length===0,errors.join(';'));
 return {catalog:30,widths:[320,390,768,1024,1440],receiptWidths:[58,80],selection:'persists across search and pages',errors};
}

