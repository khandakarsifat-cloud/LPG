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
    else if(name==='receipt_printers')data=[{tenant_id:tenant,printer:{queue_id:'fixture-queue',host_id:'fixture-host',queue_name:'Fixture Thermal',port_name:'USB001',driver_name:'Fixture',transport:'windows_usb',device:null},paper_width_mm:80,printable_width_dots:576,auto_cut:false}];
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



  await page.route('http://127.0.0.1:17891/**',route=>{if(new URL(route.request().url()).pathname==='/print')throw Error('Printing is not part of this test');return route.fulfill({json:{printers:[],usb_devices:[]}});});
  const check=(condition,message)=>{if(!condition)throw Error(message);};
  const errors=[],samples=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(origin+'/?field-control-fixtures=1#/purchases');
  const inspect=async(select,label)=>{
    await select.scrollIntoViewIfNeeded();const value=await select.inputValue();await select.click();
    await page.waitForFunction(el=>el.matches(':open'),await select.elementHandle());
    const data=await select.evaluate(el=>({appearance:getComputedStyle(el).appearance,font:parseFloat(getComputedStyle(el).fontSize),pickerFont:parseFloat(getComputedStyle(el.options[0]).fontSize),count:el.options.length,overflows:[...el.options].some(o=>{const b=o.getBoundingClientRect();return b.width>0&&(b.left<0||b.right>innerWidth+1);}),selectedVisible:[...el.selectedOptions].every(o=>{const b=o.getBoundingClientRect();return b.top>=0&&b.bottom<=innerHeight+1;})}));
    check(data.appearance==='base-select'&&!data.overflows&&data.selectedVisible,JSON.stringify({label,...data}));
    check(data.font<=14&&data.pickerFont===13,`Oversized text in ${label}`);
    await page.keyboard.press('Escape');
    check(await select.count()===1&&await select.inputValue()===value&&await select.evaluate(e=>!e.matches(':open')),`Escape changed or removed ${label}`);
    samples.push({label,...data});
  };
  for(const theme of ['light','dark'])for(const [width,height] of [[320,568],[390,844],[430,400],[768,1024],[1440,900]]){
    await page.setViewportSize({width,height});await page.evaluate(theme=>{document.documentElement.dataset.theme=theme;},theme);
    await page.goto(origin+'/#/purchases');await page.getByLabel('Search purchases',{exact:true}).waitFor();
    const font=await page.getByLabel('Search purchases',{exact:true}).evaluate(el=>parseFloat(getComputedStyle(el).fontSize));check(font===13,'Search field differs from 13px body control scale');
    await inspect(page.getByRole('combobox',{name:'Purchase status',exact:true}),`status ${theme} ${width}`);
    await inspect(page.getByRole('combobox',{name:'Payment status',exact:true}),`payment ${theme} ${width}`);
    await inspect(page.getByRole('combobox',{name:'Sort by',exact:true}),`sort ${theme} ${width}`);
    if(theme==='light'&&width===390){
      await page.screenshot({path:'.temp/field-controls/purchases-final.png'});
      const status=page.getByRole('combobox',{name:'Purchase status',exact:true});await status.click();await page.screenshot({path:'.temp/field-controls/dropdown-final.png'});await page.keyboard.press('Escape');
    }
  }
  await page.setViewportSize({width:390,height:844});
  const status=page.getByRole('combobox',{name:'Purchase status',exact:true});
  await status.click();await status.getByRole('option',{name:'Received',exact:true}).click();
  await page.getByText('No purchases match these filters.',{exact:true}).waitFor();
  check(await status.inputValue()==='received','Touch option selection did not update filter');
  await page.getByRole('button',{name:'Clear filters',exact:true}).first().click();
  await status.click();await page.keyboard.press('End');await page.keyboard.press('Enter');
  check(await status.inputValue()==='cancelled','Keyboard selection failed');
  await status.focus();await page.keyboard.press('Tab');
  check(await page.getByRole('combobox',{name:'Payment status',exact:true}).evaluate(el=>document.activeElement===el),'Tab navigation skipped the next field');
  await page.getByRole('button',{name:'Clear filters',exact:true}).first().click();
  await page.getByRole('button',{name:'Choose date: From',exact:true}).click();
  const calendar=page.getByRole('dialog',{name:'Choose date: From',exact:true});await calendar.waitFor();
  await inspect(calendar.getByRole('combobox',{name:'Calendar month',exact:true}),'calendar month');
  check(await calendar.isVisible(),'Escape in month picker closed its parent calendar');
  await page.keyboard.press('Escape');
  for(const [route,action] of [['/customers',null],['/inventory','Add Item'],['/employees','Add Employee'],['/gas-plants','Add Gas Plant'],['/purchases','New Purchase']]){
    await page.goto(origin+'/#'+route);
    if(!action)await page.locator('.customers-page').waitFor();
    if(action){await page.getByRole('button',{name:action,exact:true}).click();await page.locator('dialog[open],.modal-content').first().waitFor();}
    const selects=action?page.locator('dialog[open] select,.modal-content select'):page.locator('.page-content select');
    for(let i=0;i<await selects.count();i++)await inspect(selects.nth(i),`${route} field ${i}`).catch(error=>{throw Error(`${route} field ${i}: ${error.message}`);});
    if(action)await page.goto(origin+'/?field-controls-reset='+encodeURIComponent(route)+'#/pos');
  }
  await page.goto(origin+'/#/');await page.locator('.dashboard-workspace').waitFor();
  await page.getByRole('button',{name:'Receipt Printer',exact:true}).click();
  const printer=page.getByRole('dialog',{name:'Receipt Printer',exact:true});await printer.waitFor();
  await inspect(printer.getByRole('combobox',{name:'Printer',exact:true}),'printer dialog');
  check(await printer.isVisible(),'Escape in printer picker closed its dialog');
  await printer.getByRole('button',{name:'Close',exact:true}).click();
  await page.goto(origin+'/#/pos');await page.locator('.pos-product-card').first().waitFor();
  for(const label of ['Discount (Tk)','Exchange Fee (Tk)']){const field=page.getByLabel(label,{exact:true});await field.fill('12.50');await field.hover();await page.mouse.wheel(0,100);check(await field.inputValue()==='12.50',`${label} stepped on wheel`);}
  check(errors.length===0,errors.join('\n'));await context.close();
  return {pickers:samples.length,viewports:5,themes:2,checks:'in-page touch pickers, compact field/option fonts, constrained menus, selection, filtering, keyboard, Tab/Escape, nested calendar, modal fields and decimal entry',errors};
}
