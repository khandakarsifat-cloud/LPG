// Run with playwright-cli run-code --filename=tests/responsive.browser.cjs on a Vite or published origin.
// Isolated Auth/REST fixtures only: no real business writes or printing.
async page => {
  const origin = new URL(page.url()).origin;
  const id = n => `bf${n.toString(16).padStart(6,'0')}-0000-4000-8000-000000000001`;
  const tenant=id(1), now=new Date().toISOString();
  const user={id:id(2),aud:'authenticated',role:'authenticated',email:'pages@example.invalid',app_metadata:{},user_metadata:{},created_at:now};
  const payload=btoa(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','').replaceAll('+','-').replaceAll('/','_');
  const token='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'+payload+'.Zml4dHVyZQ';
  await page.context().addInitScript(({user,token})=>{const session=JSON.stringify({access_token:token,refresh_token:'fixture',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user});for(const host of ['127','api','localhost'])localStorage.setItem(`sb-${host}-auth-token`,session);},{user,token});
  const brands=Array.from({length:14},(_,n)=>({tenant_id:tenant,brand_id:id(10+n),brand_name:`Brand ${n+1}`,is_active:true}));
  const items=Array.from({length:30},(_,n)=>({tenant_id:tenant,item_id:id(100+n),brand_id:brands[Math.floor(n/15)].brand_id,brand:brands[Math.floor(n/15)].brand_name,size_kg:5+n%15,mouth_size:'22mm',filled_quantity:100,empty_quantity:100,lpg_brands:brands[Math.floor(n/15)]}));
  const purchaseItems=items.slice(0,7).map((item,n)=>({...item,purchase_item_id:id(300+n),brand_name:brands[0].brand_name,type:'refill',quantity:2,empty_dispatched:2,unit_price:10,billed_quantity:2,received_quantity:null,line_total:20}));
  const purchases=Array.from({length:14},(_,n)=>({purchase_id:id(400+n),plant_id:id(500),plant_name:'Fixture plant',brand_id:brands[0].brand_id,company_name:brands[0].brand_name,truck_id:null,truck_name:null,status:'created',payment_status:'unpaid',created_at:now,dispatched_at:null,received_at:null,paid_at:null,subtotal:140,commission:0,company_payable:140,transport_cost:0,labour_cost:0,total_cost:140,notes:'',receipt_notes:null,revision:1,legacy_record:false,items:structuredClone(purchaseItems)}));
  const trucks=Array.from({length:14},(_,n)=>({truck_id:id(600+n),name:`Truck ${n+1}`,serial_no:`Dhaka ${n+1}`,status:'idle',capacity:100,size:'medium',location:'Dhaka',is_active:true}));
  const transits=Array.from({length:28},(_,n)=>({transit_id:id(700+n),truck_id:trucks[n%14].truck_id,truck_name:trucks[n%14].name,purchase_id:null,status:n<14?'active':'completed',transport_fee:1000,driver_cost:10,helper_cost:10,oil_cost:10,others_cost:10,additional_costs:Array.from({length:7},(_,i)=>({name:`Cost ${i+1}`,amount:10})),total_cost:110,client_name:'Fixture client',destination:'Dhaka',description:'',revision:1,closed_at:null,created_at:now}));
  const employees=Array.from({length:13},(_,n)=>({employee_id:id(800+n),name:`Employee ${n+1}`,address:'Dhaka',current_salary:1000,business_unit:'gas_business',notes:null,is_active:true,created_at:now,updated_at:now,employee_type_id:null,employee_type_name:'Worker',phones:Array.from({length:9},(_,i)=>({phone:`017${String(n*10+i).padStart(8,'0')}`,is_primary:i===0})),primary_phone:'01700000000',payment_count:10}));
  const payments=Array.from({length:10},(_,n)=>({payment_id:id(900+n),employee_id:employees[0].employee_id,employee_name:'Employee 1',category_id:id(950),category_code:'bonus',category_name:'Bonus',category_kind:'bonus',amount:100,payment_date:'2026-10-19',description:'Fixture',salary_year:null,salary_month:null,trip_count:null,created_at:now}));
  const plants=Array.from({length:14},(_,n)=>({plant_id:id(1000+n),plant_name:`Plant ${n+1}`,brand_id:brands[0].brand_id,brand_name:brands[0].brand_name,location:'Dhaka',is_active:true,officer_id:null}));
  await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));
  const serveFixture=async route=>{
    const url=new URL(route.request().url()),name=url.pathname.split('/').pop();
    let data=[];
    if(name==='user_profiles')data=[{tenant_id:tenant,full_name:'Page Operator',email:user.email,tenants:{business_name:'Responsive verification'}}];
    else if(name==='get_my_permissions')data=['customers:view','customers:manage','finance:view','dashboard:view','pos:sell','sales:view','receipts:print','purchases:view','purchases:manage','inventory:view','inventory:manage','employees:view','employees:manage','payroll:view','payroll:pay','logistics:view','logistics:manage','settings:manage','gas_plants:view','gas_plants:manage'];
    else if(name==='wallets')data=[{type:'dealership',balance:-2354943}];
    else if(name==='items')data=items;
    else if(name==='price_books')data=items.flatMap(item=>['refill','package'].map(type=>({item_id:item.item_id,price_type:type,customer_tier:'retail',price:type==='refill'?1250:3500,effective_from:'2020-01-01',effective_to:null})));
    else if(name==='get_dashboard_stats')data={todayRevenue:123456,todayMovements:25,totalCustomers:35};
    else if(name==='get_customer_directory')data={entries:Array.from({length:6},(_,n)=>({customer_id:id(1500+n),display_name:'Customer '+n,name:'Customer '+n,tier:'retail',phone:'01712345678',address:'Dhaka',created_at:now,transactions:10,refill:5,package:2,total_sold:7,last_transaction_at:now})),total:30};
    else if(name==='get_customer_overview')data={wholesale:15,retail:15,new_wholesale:2,new_retail:3,inactive_wholesale:1,inactive_retail:2,week_start:now,inactive_since:now};
    else if(name==='list_lpg_brands')data=brands;
    else if(name==='list_trucks')data=trucks;
    else if(name==='list_transits')data=transits;
    else if(name==='list_purchases')data=purchases;
    else if(name==='list_employees')data=employees;
    else if(name==='list_employee_payments')data=payments;
    else if(name==='list_employee_payment_categories')data=[{category_id:id(950),code:'bonus',name:'Bonus',category_kind:'bonus',is_active:true}];
    else if(name==='list_gas_plants')data=plants;
    return route.fulfill({json:data});
  };
  await page.route('**/rest/v1/**',serveFixture);
  // Force a document navigation so Auth sees fixture storage before routing.
  await page.goto(origin+'/?responsive-layout-fixtures=1#/pos');
  await page.locator('.pos-item-row').first().waitFor();
  await page.evaluate(()=>document.fonts.ready);
  await page.emulateMedia({reducedMotion:'reduce'});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const failures=[],samples=[];
  const sizes=[[2560,1408],[1920,1080],[1440,900],[1366,768],[1280,600],[1100,700],[1024,768],[834,1194],[768,600],[600,400],[390,740],[390,844],[320,568]];
  const routes=['/','/pos','/inventory','/purchases','/customers','/employees','/gas-plants','/logistics','/settings','/finance'];
  for(const [width,height] of sizes){
    await page.setViewportSize({width,height});
    for(const collapsed of [false,true]){
      await page.evaluate(value=>localStorage.setItem('lpg-sidebar-collapsed',String(value)),collapsed);
      await page.goto(origin+'/#/pos');await page.reload();
      await page.locator('.pos-item-row').first().waitFor();
      for(const path of routes){
        await page.goto(origin+'/#'+path);
        await page.locator('.page-content').waitFor();
        await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
        const result=await page.evaluate(()=>{
          const content=document.querySelector('.page-content'),bar=document.querySelector('.topbar');
          const scrolling=[...document.querySelectorAll('.app-screen-scroll,.inv-tab-content,.pos-products,.pos-side-panel')].filter(e=>e.scrollHeight>e.clientHeight+2&&['auto','scroll'].includes(getComputedStyle(e).overflowY)).length;
          return {width:content.clientWidth,scroll:content.scrollWidth,root:document.documentElement.scrollWidth,viewport:innerWidth,scrolling,bar:bar.getBoundingClientRect().bottom,top:content.getBoundingClientRect().top};
        });
        if(result.scroll>result.width+2||result.root>width+2||result.scrolling||result.top<result.bar-1) failures.push({path,width,height,collapsed,...result});
      }
      await page.goto(origin+'/#/pos');await page.locator('.pos-item-row').first().waitFor();
      const pos=await page.evaluate(()=>({card:document.querySelector('.pos-product-card').getBoundingClientRect().width,empty:document.querySelector('.pos-cart-empty').getBoundingClientRect().height,lines:document.querySelector('.pos-cart-lines').getBoundingClientRect().height,columns:getComputedStyle(document.querySelector('.pos-products-grid')).gridTemplateColumns.split(' ').length}));
      if(pos.card>(width<600?401:281)||pos.empty>110||pos.lines<pos.empty)failures.push({path:'POS density',width,height,collapsed,...pos});
      samples.push({width,height,collapsed,...pos});
    }
  }
  await page.setViewportSize({width:390,height:844});
  await page.getByRole('button',{name:'Open navigation menu',exact:true}).click();
  await page.getByRole('navigation',{name:'Primary navigation'}).getByRole('link',{name:'Inventory',exact:true}).click();
  if(await page.locator('.sidebar.mobile-open').count())failures.push('Mobile drawer did not close');
  await page.goto(origin+'/#/pos');await page.locator('.pos-item-row').first().waitFor();
  for(const button of (await page.getByRole('button',{name:/^New Package for /}).all()).slice(0,8)) await button.click();
  await page.getByRole('navigation',{name:'cart lines pages'}).getByRole('button',{name:'Next page'}).click();
  await page.getByRole('navigation',{name:'cart lines pages'}).getByRole('button',{name:'Previous page'}).click();
  if(!(await page.locator('.pos-cart').textContent()).includes('28,000'))failures.push('Cart totals omitted paginated lines');
  for(const [width,height,label] of [[1920,1080,'desktop'],[1280,600,'short'],[834,1194,'tablet'],[390,844,'mobile']]){
    await page.setViewportSize({width,height});await page.locator('.page-content').evaluate(e=>e.scrollTop=0);
    await page.screenshot({path:'.temp/responsive/pos-'+label+'.png'});
  }
  await page.setViewportSize({width:1920,height:1080});
  await page.locator('.page-content').evaluate(e=>e.scrollTop=0);
  const checkout=await page.getByRole('button',{name:'Complete Checkout',exact:true}).boundingBox();
  if(!checkout||checkout.y+checkout.height>1080)failures.push('Populated desktop checkout clipped');
  await page.setViewportSize({width:390,height:844});
  await page.locator('.page-content').evaluate(e=>e.scrollTop=0);
  await page.getByRole('button',{name:'Checkout (8)',exact:true}).click();
  await page.getByRole('button',{name:'Complete Checkout',exact:true}).scrollIntoViewIfNeeded();
  await page.getByRole('button',{name:'Back to products',exact:true}).click();
  // Large record counts, long labels and short dialogs use the same real components.
  for(const [path,name] of [['/inventory','Add Item'],['/logistics','Add Truck'],['/gas-plants','Add Gas Plant'],['/employees','Add Employee'],['/purchases','New Purchase'],['/customers','Add customer']]){
    await page.goto(origin+'/#'+path);await page.getByRole('button',{name,exact:true}).click();
    await page.locator('.modal-overlay,dialog[open]').first().waitFor();
    for(const [width,height] of [[320,568],[600,400],[1100,700]]){
      await page.setViewportSize({width,height});
      await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
      await page.waitForFunction(()=>{
        const panel=document.querySelector('dialog[open]')||document.querySelector('.modal-content');
        if(!panel)return false;const b=panel.getBoundingClientRect();
        return b.left>=0&&b.right<=innerWidth+1&&b.top>=0&&b.bottom<=innerHeight+1&&panel.scrollWidth<=panel.clientWidth+2;
      },null,{timeout:3000});
      const overflow=await page.evaluate(()=>{
        const panel=document.querySelector('dialog[open]')||document.querySelector('.modal-content');
        if(!panel)return 'Missing panel';
        const b=panel.getBoundingClientRect();
        return {overflow:b.left<0||b.right>innerWidth+1||b.top<0||b.bottom>innerHeight+1||panel.scrollWidth>panel.clientWidth+2,box:{left:b.left,right:b.right,top:b.top,bottom:b.bottom},viewport:[innerWidth,innerHeight],scroll:panel.scrollWidth,client:panel.clientWidth};
      });
      if(overflow.overflow)failures.push({path,width,height,dialog:overflow});
    }
    await page.goto(origin+'/#/pos');await page.reload();await page.locator('.pos-item-row').first().waitFor();
  }
  // Minimal content must not stretch into unused space.
  items.splice(4);await page.reload();await page.locator('.pos-item-row').first().waitFor();
  await page.setViewportSize({width:2560,height:1408});
  const minimal=await page.evaluate(()=>({count:document.querySelectorAll('.pos-product-card').length,width:document.querySelector('.pos-product-card').getBoundingClientRect().width,cart:document.querySelector('.pos-side-panel').getBoundingClientRect().height}));
  if(minimal.count!==4||minimal.width>281||minimal.cart>750)failures.push({minimal});
  await page.screenshot({path:'.temp/responsive/pos-minimal.png'});
  const cdp=await page.context().newCDPSession(page);
  for(const scale of [1.25,2]){
    await cdp.send('Emulation.setDeviceMetricsOverride',{width:1024,height:680,deviceScaleFactor:scale,mobile:false});
    const scaled=await page.evaluate(()=>({ratio:devicePixelRatio,overflow:document.querySelector('.page-content').scrollWidth>document.querySelector('.page-content').clientWidth+2}));
    if(scaled.overflow||scaled.ratio!==scale)failures.push({scale,...scaled});
  }
  await cdp.send('Emulation.clearDeviceMetricsOverride');await cdp.detach();
  const touchContext=await page.context().browser().newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true,deviceScaleFactor:2,userAgent:'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',storageState:await page.context().storageState()});
  const touch=await touchContext.newPage();
  await touch.route('**/auth/v1/**',route=>route.fulfill({json:user}));
  await touch.route('**/rest/v1/**',serveFixture);
  await touch.goto(origin+'/?responsive-touch=1#/pos');await touch.locator('.pos-item-row').first().waitFor();
  for(const [width,height] of [[320,568],[360,800],[390,740],[390,844],[412,915],[430,932],[768,600]]){
    await touch.setViewportSize({width,height});
    await touch.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    const details=await touch.evaluate(()=>{const box=selector=>document.querySelector(selector).getBoundingClientRect();return {overflow:document.querySelector('.page-content').scrollWidth>document.querySelector('.page-content').clientWidth+2,target:box('.pos-item-stepper-btn').width,font:parseFloat(getComputedStyle(document.querySelector('input.input-field')).fontSize),columns:getComputedStyle(document.querySelector('.pos-products-grid')).gridTemplateColumns.split(' ').length,productsWidth:box('.pos-product-card').width,checkoutWidth:box('.pos-side-panel').width,workspaceWidth:box('.pos-workspace').width,checkoutBelow:box('.pos-side-panel').top>=box('.pos-products').bottom};});
    const phoneMisaligned=width<600&&(details.columns!==1||Math.abs(details.productsWidth-details.workspaceWidth)>1||Math.abs(details.checkoutWidth-details.workspaceWidth)>1);
    if(details.overflow||details.target<28||details.font!==13||phoneMisaligned||!details.checkoutBelow)failures.push({touch:true,width,height,...details});
  }
  await touch.setViewportSize({width:390,height:844});
  const amount=touch.getByLabel('Discount (Tk)',{exact:true});
  await amount.fill('125.50');
  await touch.setViewportSize({width:390,height:400});
  await amount.scrollIntoViewIfNeeded();
  const keyboardResize=await amount.evaluate(el=>({value:el.value,focused:document.activeElement===el,bottom:el.getBoundingClientRect().bottom,viewport:innerHeight,columns:getComputedStyle(document.querySelector('.pos-products-grid')).gridTemplateColumns.split(' ').length}));
  if(keyboardResize.value!=='125.50'||!keyboardResize.focused||keyboardResize.bottom>keyboardResize.viewport||keyboardResize.columns!==1)failures.push({keyboardResize});
  await touchContext.close();
  const anonymous=await page.context().browser().newContext();
  const auth=await anonymous.newPage();
  for(const path of ['/login','/register'])for(const [width,height] of [[320,568],[768,600],[1440,900]]){
    await auth.setViewportSize({width,height});await auth.goto(origin+'/#'+path);
    await auth.locator('.auth-root').waitFor();
    const overflow=await auth.evaluate(()=>document.documentElement.scrollWidth>innerWidth+2);
    if(overflow)failures.push({path,width,height,authOverflow:true});
  }
  await anonymous.close();
  if(failures.length||errors.length)throw Error(JSON.stringify({failures,errors}));
  return {layouts:sizes.length*2*routes.length,samples,minimal,dialogLayouts:18,authLayouts:6,touchLayouts:7,keyboardResize,scales:[1.25,2],failures,errors};
}
