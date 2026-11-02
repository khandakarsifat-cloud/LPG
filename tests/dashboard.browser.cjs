// Intercepted UI/device fixtures only. Independent accounting acceptance is in dashboard.sql.
async page => {
  const base = new URL(page.url()).origin;
  const tenant = 'dc020000-0000-4000-8000-000000000001', saleId = 'dc020000-0000-4000-8000-000000000003';
  const user = { id: 'dc020000-0000-4000-8000-000000000002', email: 'dashboard@example.invalid', aud: 'authenticated', role: 'authenticated', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
  const token = 'eyJhbGciOiJIUzI1NiJ9.' + btoa(JSON.stringify({ sub: user.id, exp: Math.floor(Date.now()/1000)+86400, aud:'authenticated',role:'authenticated' })).replaceAll('=','') + '.Zml4dHVyZQ';
  await page.context().addInitScript(({ user, token }) => {
    const session = JSON.stringify({ user, access_token:token,refresh_token:'fixture',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,token_type:'bearer' });
    for (const host of ['api.lpg.144.79.249.4.sslip.io','127.0.0.1:54321','localhost:54321']) localStorage.setItem(`sb-${host}-auth-token`,session);
    localStorage.removeItem('lpg:print-bridge:url'); localStorage.removeItem('lpg:print-bridge:token');
  }, { user, token });
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date());const now=new Date().toISOString();
  let saved=null,empty=false,fail=false,prints=0,scans=0,threshold=5;let customType=false,typeReads=0,releaseInitial;const initialRead=new Promise(resolve=>{releaseInitial=resolve;});
  const snapshot=()=>({date:today,generated_at:now,finance_visible:true,days:Array.from({length:7},(_,i)=>({date:today,revenue:empty?0:[72000,81000,75000,89000,92000,112000,125430][i],expense:empty?0:42680+i*10,collected:empty?0:70000+i*2000,sales:empty?0:26+i})),
    sales:empty?[]:Array.from({length:5},(_,i)=>({sale_id:i?saleId.replace(/003$/,'00'+(i+3)):saleId,created_at:now,customer:['Rahim Stores','Karim Hotel & Restaurant','Mitu Traders','Bashundhara Canteen','Ayesha Store'][i],items:['LPG 12 kg × 2','LPG 45 kg × 1, Regulator × 1','LPG 15 kg × 3 (Package)','LPG 30 kg × 1','LPG 12 kg × 1, Lighter × 2'][i],amount:[2850,4950,4650,3400,1520][i]})),
    bottles:[12,15,30,35,45,17].map((size_kg,i)=>({size_kg,quantity:empty?0:[14,8,5,2,3,0][i]})),stove_types:['Single Stove','Double Stove','Regulator','Pipe','Others','Custom fitting'].map((name,i)=>({type_id:String(i),name,system_key:['single_stove','double_stove','regulator','pipe','others',null][i],quantity:empty?0:[6,3,11,18,24,0][i]})).concat(customType?[{type_id:'new-type',name:'Added during initial read',system_key:null,quantity:0}]:[]),
    attention:{customer_due:empty?0:48750,customers:empty?0:12,low_stock:empty?0:3,bottles:empty?0:15,bottle_customers:empty?0:4},activity:{hasMore:false,entries:empty?[]:['sale','purchase','payment','financial_entry'].map((kind,i)=>({id:String(i),kind,record_kind:kind==='payment'?'sale':kind,record_id:saleId,title:['POS sale','Purchase · received','Customer payment','Financial entry · Transport'][i],description:['Rahim Stores','Providence LPG','Karim Hotel','Transport'][i],amount:[2850,18500,20000,1200][i],created_at:new Date(Date.now()-i*3600000).toISOString()}))}});
  await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));
  await page.route('**/rest/v1/**',async route=>{
    const name=new URL(route.request().url()).pathname.split('/').pop();let data=[];
    if(name==='user_profiles')data=[{tenant_id:tenant,full_name:'Dashboard Owner',email:user.email,tenants:{business_name:'Dashboard development fixture'}}];
    if(name==='get_my_permissions')data=['dashboard:view','pos:sell','sales:view','receipts:print','printers:manage','inventory:view','inventory:manage','customers:view','customers:manage','finance:view','finance:manage','purchases:view','settings:manage'];
    if(name==='get_my_preferences')data={theme:null};
    if(name==='get_stove_product_types'){const initial=[{type_id:'old-type',name:'Existing type',is_active:true,system_key:null}];if(++typeReads===1){await initialRead;await new Promise(resolve=>setTimeout(resolve,200));try{await route.fulfill({json:initial});}catch{/* Expected when the stale initial read is cancelled. */}return;}data=initial.concat(customType?[{type_id:'new-type',name:'Added during initial read',is_active:true,system_key:null}]:[]);}
    if(name==='save_stove_product_type'){customType=true;data='new-type';releaseInitial();}
    if(name==='wallets')data=[{wallet_id:'cash',type:'cash',name:'Cash Register',balance:1079527},{wallet_id:'bank',type:'custom',name:'Bank',balance:900000}];
    if(name==='get_dashboard_snapshot'){if(fail)return route.fulfill({status:500,json:{message:'Fixture snapshot unavailable'}});data=snapshot();}
    if(name==='get_dashboard_activity')data=snapshot().activity;
    if(name==='receipt_printers'){if(route.request().method()==='POST')saved=route.request().postDataJSON();data=saved?[saved]:[];}
    if(name==='get_customer_overview')data={wholesale:0,retail:0,new_wholesale:0,new_retail:0,inactive_wholesale:0,inactive_retail:0,week_start:today,inactive_since:today};
    if(name==='get_customer_directory'||name==='get_sales_directory')data={entries:[],total:0};
    if(name==='get_stock_alerts')data={total:1,entries:[{item_id:saleId,name:'Fixture regulator',business_category:'stove',filled_quantity:2,low_stock_threshold:threshold}]};
    if(name==='set_stock_threshold'){threshold=route.request().postDataJSON().p_threshold;data=null;}
    if(name==='get_inventory_valuation')data={known_value:0,lpg_value:0,stove_value:0,reconstructed_products:0};
    if(name==='get_sales_overview')data={total:0,amount:0,due:0,bottles:0};
    if(name==='get_payment_wallets')data=[{wallet_id:saleId,name:'Cash Register',kind:'cash',type:'cash'}];
    if(name==='get_financial_catalog')data={types:[],categories:[],businesses:[]};
    if(name==='get_business_catalogs')data={roles:[],weights:[]};
    if(name==='get_attendance_configuration')data={timezone:'Asia/Dhaka',cutoff:'00:00',next_cutoff:'00:00',has_events:false,devices:[]};
    if(route.request().headers().accept?.includes('application/vnd.pgrst.object+json')&&Array.isArray(data))data=data[0]??null;
    await route.fulfill({json:data});
  });
  await page.route('http://127.0.0.1:17891/**',async route=>{
    const path=new URL(route.request().url()).pathname;
    if(path==='/printers')return route.fulfill({json:{printers:[],usb_devices:[],network_subnets:['192.168.1.0/24']}});
    if(path==='/network/test')return route.fulfill({json:{connected:true,message:'TCP reachable. Print a test receipt to confirm ESC/POS.'}});
    if(path==='/network/discover'){scans++;return route.fulfill({json:{printers:[{transport:'network_tcp',ip_address:'192.168.1.55',port:9100,protocol:'escpos',device:null,queue_id:'tcp:192.168.1.55:9100',host_id:'local-network',queue_name:'Network printer 192.168.1.55',port_name:'192.168.1.55:9100',driver_name:'ESC/POS over TCP',supported:true,available:true}]}});}
    if(path==='/print'){prints++;return route.fulfill({json:{job_id:prints,message:'Receipt bytes sent to network printer (fixture).'}});}
    return route.abort();
  });
  const check=(ok,message)=>{if(!ok)throw Error(message);};
  const go=async()=>{await page.goto(base+'/#/');await page.getByRole('heading',{name:"Today's Revenue",exact:true}).waitFor();await page.getByText('Tk 1,25,430.00',{exact:true}).waitFor();};
  await page.reload();await go();
  check(await page.locator('.dashboard-stove-types .dashboard-bottle').count()===6,'All five defaults and the custom type are visible');
  check(await page.locator('[data-stove-type="regulator"]').innerText()==='Regulator\n11 units','Type quantity and dedicated icon identity');
  const customColor=await page.locator('[data-stove-type="custom"]').getAttribute('class');await page.reload();await go();
  check(await page.locator('[data-stove-type="custom"]').getAttribute('class')===customColor,'Custom icon color remains stable after reload');
  check(await page.locator('.topbar-wallet').innerText()==='Cash Register\nTk 10,79,527.00','Cash Register must exclude the second wallet');
  check(await page.getByRole('link',{name:/New Sale|New Purchase/}).count()===0,'Dashboard creation buttons removed');
  for(const width of [1672,1440,1024,768,390,360,320]){
    await page.setViewportSize({width,height:width<600?850:1000});
    const overflow=await page.evaluate(()=>[document.documentElement,...document.querySelectorAll('.page-content,.dashboard-page,.dashboard-columns')].filter(e=>e.scrollWidth>e.clientWidth+1).map(e=>e.className));
    check(!overflow.length,`Dashboard overflow at ${width}: ${overflow}`);
    for(const name of ['Needs Attention','Recent Activity','LPG Bottles Sold Today','Stove-Business Products Sold Today'])check(await page.getByRole('heading',{name,exact:true}).count()===1,`Missing ${name}`);
    await page.screenshot({path:`.temp/dashboard/dashboard-${width}.png`,fullPage:true});
  }
  await page.setViewportSize({width:1440,height:1000});
  await page.locator('.dashboard-attention-entry').filter({hasText:'Customer Dues'}).click();await page.getByLabel('Dues',{exact:true}).waitFor();check(await page.getByLabel('Dues',{exact:true}).inputValue()==='payment','Customer dues link applies filter');
  await go();await page.locator('.dashboard-attention-entry').filter({hasText:'Bottle Dues'}).click();await page.getByLabel('Dues',{exact:true}).waitFor();check(await page.getByLabel('Dues',{exact:true}).inputValue()==='bottle','Bottle dues filter');
  await go();await page.locator('.dashboard-attention-entry').filter({hasText:'Low Stock'}).click();await page.getByRole('heading',{name:'Stock alerts',exact:true}).waitFor();check(await page.getByLabel('Below threshold only').isChecked(),'Low-stock filter');await page.getByLabel('Low stock threshold for Fixture regulator').fill('4');await page.getByRole('button',{name:'Save',exact:true}).click();await page.getByText('Stock threshold saved',{exact:true}).waitFor();check(threshold===4,'Threshold saved');
  await go();await page.getByRole('link',{name:'View All Sales'}).click();await page.getByLabel('From',{exact:true}).waitFor();check(await page.getByLabel('From',{exact:true}).inputValue()===today,'Sales date filter');
  await go();await page.getByRole('button',{name:'View All',exact:true}).click();await page.getByRole('dialog',{name:'Recent activity',exact:true}).waitFor();await page.getByRole('dialog',{name:'Recent activity',exact:true}).getByRole('button',{name:'Close dialog',exact:true}).click();
  await page.getByRole('button',{name:'POS Printer',exact:true}).click();const modal=page.getByRole('dialog',{name:'POS Printer',exact:true});
  await modal.getByRole('button',{name:/^Ethernet printer/}).click();check(await modal.getByRole('switch',{name:'Auto-cut after receipt'}).isChecked(),'Auto-cut defaults on for a new printer');await modal.getByLabel('Printer IP address',{exact:true}).fill('192.168.1.50');
  await modal.getByRole('button',{name:'Test Connectivity',exact:true}).click();await modal.getByText(/Connected\. TCP reachable/).waitFor();
  await modal.getByRole('button',{name:'Discover Network Printers',exact:true}).click();await modal.getByText(/1 reachable endpoint\. Select one below/).waitFor();check(scans===1,'Network discovered');
  await modal.getByRole('button',{name:/192\.168\.1\.55/}).click();check(await modal.getByLabel('Printer IP address',{exact:true}).inputValue()==='192.168.1.55','Inline discovered network printer selected');
  for(const width of [1440,768,390,320]){await page.setViewportSize({width,height:900});check(await modal.locator('.modal-body').evaluate(el=>el.scrollWidth<=el.clientWidth),'Printer modal fits '+width);await page.screenshot({path:`.temp/dashboard/printer-${width}.png`});}await page.setViewportSize({width:1440,height:1000});
  await modal.getByRole('button',{name:'Print Test Receipt',exact:true}).click();await modal.getByText('Receipt bytes sent to network printer (fixture).',{exact:true}).waitFor();check(prints===1,'One explicit test receipt');
  await modal.getByLabel('Paper width',{exact:true}).selectOption('58');check(await modal.getByLabel('Printable width (dots)',{exact:true}).inputValue()==='384','58mm profile selected');
  await modal.getByRole('button',{name:'Save Printer',exact:true}).click();await modal.waitFor({state:'hidden'});check(saved.printer.transport==='network_tcp'&&saved.printer.ip_address==='192.168.1.55'&&saved.paper_width_mm===58&&saved.auto_cut===true,'Ethernet config and default cutting saved');
  await page.getByRole('button',{name:'POS Printer',exact:true}).click();await modal.getByLabel('Printer IP address',{exact:true}).waitFor();check(await modal.getByLabel('Printer IP address',{exact:true}).inputValue()==='192.168.1.55','Saved preference restored');
  check(await modal.getByRole('switch',{name:'Auto-cut after receipt'}).isChecked(),'Cut setting survives reload');await modal.getByRole('switch',{name:'Auto-cut after receipt'}).uncheck();await modal.getByRole('button',{name:'Save Printer',exact:true}).click();await modal.waitFor({state:'hidden'});await page.getByRole('button',{name:'POS Printer',exact:true}).click();check(!(await modal.getByRole('switch',{name:'Auto-cut after receipt'}).isChecked()),'Explicit cutter off survives reopening');
  await modal.getByLabel('Printer IP address',{exact:true}).fill('8.8.8.8');check(await modal.getByRole('button',{name:'Save Printer',exact:true}).isDisabled(),'Public printer address cannot be saved');await modal.getByRole('button',{name:'Cancel',exact:true}).click();
  await page.goto(base+'/#/settings');await page.getByRole('button',{name:'Stove product types',exact:true}).click();await page.getByLabel('Type name',{exact:true}).fill('Added during initial read');await page.getByRole('button',{name:'Add type',exact:true}).click();await page.getByText('Added during initial read',{exact:true}).waitFor({timeout:5000});check(typeReads>=2,'Save cancels and refetches the pending initial type read');await go();await page.locator('.dashboard-stove-types').getByText('Added during initial read',{exact:true}).waitFor();
  empty=true;await page.reload();await page.getByText('No sales recorded today.',{exact:true}).waitFor();check(await page.getByText('No business activity recorded yet.',{exact:true}).count()===1,'Empty business activity');check(await page.locator('.dashboard-stove-types .dashboard-bottle').count()===7,'Zero-sales type cards remain visible');check(await page.locator('.dashboard-stove-types').getByText('0 units',{exact:true}).count()===7,'Empty type quantities show zero');
  fail=true;await page.reload();await page.getByRole('alert').filter({hasText:'Dashboard data could not be loaded.'}).waitFor();check(await page.locator('.dashboard-metric-value').filter({hasText:'Restricted'}).count()===0,'Failed queries must not show invented zeros');
  check(errors.length===0,errors.join(' | '));
  return {passed:true,widths:[1672,1440,1024,768,390,360,320],networkPrints:prints,networkScans:scans,scope:'intercepted UI and printer fixtures'};
}
