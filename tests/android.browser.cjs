// Run with playwright-cli on a Vite or published origin. Android touch fixtures; no real writes.
// Isolated Auth/REST fixtures only: no real business writes or printing.
async page => {
  let minimal=false; const origin = new URL(page.url()).origin; const context=await page.context().browser().newContext({viewport:{width:390,height:844},hasTouch:true,isMobile:true,deviceScaleFactor:1});page=await context.newPage();
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
    else if(name==='get_my_permissions')data=['customers:view','customers:manage','finance:view','dashboard:view','pos:sell','sales:view','receipts:print','printers:manage','purchases:view','purchases:manage','inventory:view','inventory:manage','employees:view','employees:manage','payroll:view','payroll:pay','logistics:view','logistics:manage','settings:manage','gas_plants:view','gas_plants:manage'];
    else if(name==='wallets')data=[{type:'dealership',balance:-2354943},{type:'logistics',balance:500000}];
    else if(name==='items')data=items;
    else if(name==='price_books')data=items.flatMap(item=>['refill','package'].map(type=>({item_id:item.item_id,price_type:type,customer_tier:'retail',price:type==='refill'?1250:3500,effective_from:'2020-01-01',effective_to:null})));
    else if(name==='sales')data=minimal?[]:Array.from({length:3},(_,n)=>({sale_id:id(1700+n),customer_name:'Fixture customer '+n,customers:{name:'Fixture customer '+n},sale_tier:'retail',created_at:now,total_amount:1250,status:'completed'}));
    else if(name==='get_dashboard_stats')data={todayRevenue:123456,todayMovements:25,totalCustomers:35};
    else if(name==='get_customer_directory')data={entries:Array.from({length:minimal?0:Number(route.request().postDataJSON()?.p_limit??6)},(_,n)=>({customer_id:id(1500+n),display_name:'Customer '+n,name:'Customer '+n,tier:'retail',phone:'01712345678',address:'Dhaka',created_at:now,transactions:10,refill:5,package:2,total_sold:7,last_transaction_at:now})),total:30};
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


  const failures=[],errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.emulateMedia({reducedMotion:'reduce'});
  const routes=[['/','.dashboard-workspace'],['/inventory','.inventory-page'],['/purchases','.purchases-page'],['/customers','.customers-page'],['/employees','.employees-page'],['/gas-plants','.gas-plants-grid'],['/logistics','.inv-tabs'],['/settings','.settings-tabs'],['/finance','.empty-state'],['/pos','.pos-workspace']];
  await page.goto(origin+'/?android-pages-fixtures=1#/');
  const sizes=[[320,568],[360,800],[390,844],[430,932],[768,1024],[800,600]];
  let layouts=0;
  for(const theme of ['light','dark'])for(const [width,height] of sizes){
    await page.setViewportSize({width,height});
    await page.evaluate(theme=>{localStorage.setItem('lpg-theme',theme);document.documentElement.dataset.theme=theme;},theme);
    for(const [route,selector] of routes){
      await page.goto(origin+'/#'+route);await page.locator(selector).first().waitFor();
      await page.evaluate(()=>document.fonts.ready);
      await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
      const data=await page.evaluate(()=>{
        const content=document.querySelector('.page-content'),box=e=>e.getBoundingClientRect();
        return {overflow:content.scrollWidth>content.clientWidth+2,tableOverflow:[...document.querySelectorAll('.mobile-record-table')].some(e=>box(e).width>content.clientWidth-20),smallValues:[...document.querySelectorAll('.stat-value')].some(e=>parseFloat(getComputedStyle(e).fontSize)<18),selects:[...document.querySelectorAll('select.input-field')].map(e=>({appearance:getComputedStyle(e).appearance,height:e.clientHeight,line:parseFloat(getComputedStyle(e).lineHeight)})),header:document.querySelector('.page-header')?box(document.querySelector('.page-header')).height:0};
      });
      if(data.overflow||data.smallValues||(width<=600&&(data.tableOverflow||data.header>160))||data.selects.some(e=>e.appearance!=='base-select'||e.height<e.line))failures.push({theme,width,height,route,...data});
      if(width===390&&theme==='light')await page.screenshot({path:'.temp/android-app/'+(route==='/'?'dashboard':route.slice(1))+'-after.png'});
      layouts++;
    }
  }
  await page.setViewportSize({width:390,height:844});
  await page.goto(origin+'/#/inventory');await page.locator('.inv-tile:not(.inv-tile-skeleton)').first().waitFor();
  if(await page.locator('.inv-tile').count()!==6)failures.push('Phone stock catalog must show six products');
  await page.getByRole('navigation',{name:'products pages'}).getByRole('button',{name:'Next page'}).click();
  if(await page.locator('.inv-tile').count()!==6)failures.push('Phone stock catalog next page missing');
  await page.goto(origin+'/#/employees');await page.locator('.employees-table tbody tr').first().waitFor();
  if(await page.locator('.employees-table tbody tr').count()!==4)failures.push('Phone employee page must show four records');
  await page.locator('.employee-select').nth(1).click();
  const selected=await page.locator('.employees-detail-panel').evaluate(e=>({top:e.getBoundingClientRect().top,text:e.querySelector('h2')?.textContent}));
  if(selected.top<0||selected.top>844||selected.text!=='Employee 2')failures.push({employeeSelection:selected});
  await page.goto(origin+'/#/logistics');await page.locator('.fleet-table').waitFor();
  if(await page.locator('.fleet-table tbody tr').count()!==4)failures.push('Phone fleet must show four records');
  await page.getByTitle('Edit location',{exact:true}).first().click();
  await page.getByPlaceholder('e.g. Warehouse A').fill('A long warehouse location');
  const location=await page.getByPlaceholder('e.g. Warehouse A').evaluate(e=>e.closest('td').scrollWidth<=e.closest('td').clientWidth+2);
  if(!location)failures.push('Fleet location editor overflows');
  await page.getByTitle('Cancel',{exact:true}).first().click();
  await page.getByRole('button',{name:'Transits & Trips',exact:true}).click();await page.locator('.transit-card').first().waitFor();
  if(await page.locator('.transit-card').count()!==8)failures.push('Phone transit groups must each show four records');
  await page.screenshot({path:'.temp/android-app/transits-after.png'});
  await page.goto(origin+'/#/settings');await page.getByRole('button',{name:/LPG Brands/}).click();await page.locator('.brand-card').first().waitFor();
  if(await page.locator('.brand-card').count()!==4)failures.push('Phone brands must show four records');
  await page.screenshot({path:'.temp/android-app/brands-after.png'});
  for(const [route,name] of [['/inventory','Add Item'],['/employees','Add Employee'],['/logistics','Add Truck'],['/gas-plants','Add Gas Plant'],['/purchases','New Purchase'],['/customers','Add customer']]){
    await page.goto(origin+'/#'+route);await page.getByRole('button',{name,exact:true}).click();
    const panel=page.locator('dialog[open],.modal-content').first();await panel.waitFor();
    for(const [width,height] of [[320,568],[390,400]]){
      await page.setViewportSize({width,height});
      await page.waitForFunction(()=>{const el=document.querySelector('dialog[open],.modal-content'),b=el?.getBoundingClientRect();return b&&b.top>=0&&b.bottom<=innerHeight+1;});
      const overflow=await panel.evaluate(e=>e.scrollWidth>e.clientWidth+2||[...e.querySelectorAll('.modal-body')].some(b=>b.scrollWidth>b.clientWidth+2));
      if(overflow)failures.push({dialog:route,width,height,overflow});
    }
    await page.goto(origin+'/?android-dialog-reset='+encodeURIComponent(route)+'#/pos');
    await page.setViewportSize({width:390,height:844});
  }
  await page.goto(origin+'/#/');await page.locator('.dashboard-workspace').waitFor();await page.getByRole('button',{name:'Open navigation'}).click();
  if(!await page.getByRole('navigation',{name:'Primary navigation'}).isVisible())failures.push('Navigation drawer missing');
  await page.getByRole('navigation',{name:'Primary navigation'}).getByRole('link',{name:'Inventory',exact:true}).click();
  if(await page.locator('.sidebar.mobile-open').count())failures.push('Drawer stays open after navigation');
  minimal=true;items.splice(0);brands.splice(0);purchases.splice(0);employees.splice(0);trucks.splice(0);transits.splice(0);plants.splice(0);
  for(const [route] of routes){await page.goto(origin+'/?android-empty='+encodeURIComponent(route)+'#'+route);await page.locator('.page-content').waitFor();await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));if(await page.locator('.page-content').evaluate(e=>e.scrollWidth>e.clientWidth+2))failures.push({empty:route});}
  const anonymous=await page.context().browser().newContext({hasTouch:true,isMobile:true,viewport:{width:390,height:844}}),auth=await anonymous.newPage();
  for(const route of ['/login','/register']){
    await auth.goto(origin+'/#'+route);await auth.locator('.auth-form-title').waitFor();
    const form=await auth.locator('.auth-form-card').boundingBox();if(form.y>100)failures.push({auth:route,form});
    if(await auth.evaluate(()=>document.documentElement.scrollWidth>innerWidth+2))failures.push({auth:route,overflow:true});
    await auth.screenshot({path:'.temp/android-app/'+route.slice(1)+'-after.png'});
  }
  await anonymous.close();await context.close();
  if(failures.length||errors.length)throw Error(JSON.stringify({failures,errors}));
  return {layouts,phoneDirectories:5,touchDialogs:12,emptyRoutes:routes.length,authRoutes:2,checks:'all routes in light/dark, readable records/actions, styled touch selects, pagination, employee detail jump, inline location entry, tabs, drawer and forms',errors,failures};
}
