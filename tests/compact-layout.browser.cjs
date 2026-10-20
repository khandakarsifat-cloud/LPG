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
    else if(name==='wallets')data=[{type:'dealership',balance:10000}];
    else if(name==='items')data=items;
    else if(name==='price_books')data=items.flatMap(item=>['refill','package'].map(type=>({item_id:item.item_id,price_type:type,customer_tier:'retail',price:type==='refill'?1250:3500,effective_from:'2020-01-01',effective_to:null})));
    else if(name==='get_dashboard_stats')data={todayRevenue:123456,todayMovements:25,totalCustomers:35};
    else if(name==='get_customer_directory')data={entries:Array.from({length:12},(_,n)=>({customer_id:id(1500+n),display_name:'Customer '+n,name:'Customer '+n,tier:'retail',phone:'01712345678',address:'Dhaka',created_at:now,transactions:10,refill:5,package:2,total_sold:7,last_transaction_at:now})),total:30};
    else if(name==='get_customer_overview')data={wholesale:15,retail:15,new_wholesale:2,new_retail:3,inactive_wholesale:1,inactive_retail:2,week_start:now,inactive_since:now};
    else if(name==='list_lpg_brands')data=brands;
    else if(name==='list_trucks')data=trucks;
    else if(name==='list_transits')data=transits;
    else if(name==='list_purchases')throw Error('Unbounded purchase read');
    else if(name==='get_purchase_directory')data=purchasePage(route.request().postDataJSON());
    else if(name==='get_purchase_overview')data=purchaseOverview();
    else if(name==='get_purchases_by_ids')data=purchases.filter(p=>route.request().postDataJSON().p_ids.includes(p.purchase_id));
    else if(name==='list_employees')data=employees;
    else if(name==='list_employee_payments')data=payments;
    else if(name==='list_employee_payment_categories')data=[{category_id:id(950),code:'bonus',name:'Bonus',category_kind:'bonus',is_active:true}];
    else if(name==='list_gas_plants')data=plants;
    return route.fulfill({json:data});
  };

  const purchasePage = (args) => {
    const f={search:'',status:'all',payment:'all',from:'',to:'',sort:'date_desc',...args.p_filters};
    const groups=f.search.toLowerCase().split(',').map(g=>g.trim().split(/\s+/).filter(Boolean)).filter(g=>g.length);
    const rows=purchases.filter(p=>{
      const day=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dhaka',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(p.created_at));
      const text=[p.purchase_id,p.company_name,p.plant_name,p.truck_name,p.notes,p.receipt_notes,p.status,p.payment_status,...p.items.flatMap(i=>[i.brand_name,`${i.size_kg}kg`,`${i.size_kg} kg`,i.mouth_size,i.type==='refill'?'refill exchange':'package new cylinders'])].join(' ').toLowerCase();
      return (f.status==='all'||p.status===f.status)&&(f.payment==='all'||p.payment_status===f.payment)&&(!f.from||day>=f.from)&&(!f.to||day<=f.to)&&(!groups.length||groups.some(g=>g.every(t=>text.includes(t))));
    }).sort((a,b)=>{
      const d=f.sort.startsWith('amount')?Number(a.total_cost)-Number(b.total_cost):Date.parse(a.created_at)-Date.parse(b.created_at);
      return (f.sort.endsWith('desc')?-d:d)||a.purchase_id.localeCompare(b.purchase_id);
    });
    return {total:rows.length,entries:rows.slice(args.p_offset||0,(args.p_offset||0)+(args.p_limit||6))};
  };
  const purchaseOverview=()=>{
    const unpaid=purchases.filter(p=>p.payment_status==='unpaid'&&!['created','cancelled'].includes(p.status));
    return {total:purchases.length,created:purchases.filter(p=>p.status==='created').length,in_transit:purchases.filter(p=>p.status==='in_transit').length,unpaid:unpaid.length,company_payable:unpaid.reduce((sum,p)=>sum+Number(p.company_payable),0)};
  };
  await page.route('**/rest/v1/**',serveFixture);
  items.splice(4);brands[0].brand_name='Jamuna Gas';brands[1].brand_name='Omera Gas';
  items.forEach((item,n)=>{item.size_kg=n%2?12:25;item.lpg_brands=brands[n<2?0:1];item.brand_id=item.lpg_brands.brand_id;});
  await page.goto(origin+'/?compact-pos-check=1#/pos');await page.locator('.pos-product-card').first().waitFor();await page.evaluate(()=>document.fonts.ready);
  await page.emulateMedia({reducedMotion:'reduce'});
  const results=[],failures=[];
  for(const [width,height,collapsed,columns] of [[1360,740,true,4],[1350,734,false,3],[1100,760,false,2],[1280,800,false,3],[1280,600,true,4],[834,1112,true,2],[768,600,false,2]]){
    await page.setViewportSize({width,height});await page.evaluate(value=>localStorage.setItem('lpg-sidebar-collapsed',String(value)),collapsed);await page.reload();await page.locator('.pos-product-card').first().waitFor();
    const data=await page.evaluate(()=>{const box=e=>e.getBoundingClientRect();const cards=[...document.querySelectorAll('.pos-product-card')],first=box(cards[0]);const checkout=box(document.querySelector('.pos-side-panel'));const button=box([...document.querySelectorAll('button')].find(e=>e.textContent.includes('Complete Checkout')));return {columns:cards.filter(e=>Math.abs(box(e).top-first.top)<2).length,cardWidth:first.width,cardHeight:first.height,checkoutWidth:checkout.width,checkoutTop:checkout.top,productsBottom:box(document.querySelector('.pos-products')).bottom,checkoutBottom:checkout.bottom,buttonBottom:button.bottom,overlap:[...document.querySelectorAll('.pos-item-row')].some(e=>box(e.querySelector('.pos-option-label')).right+3>box(e.querySelector('.pos-option-controls')).left),overflow:document.querySelector('.page-content').scrollWidth>document.querySelector('.page-content').clientWidth+2};});
    results.push({width,height,collapsed,...data});
    const misplaced=width>=1200 ? data.checkoutWidth>281||data.checkoutBottom>height||data.buttonBottom>height : data.checkoutTop<data.productsBottom||data.checkoutWidth>321;
    if(data.columns!==columns||data.cardWidth>281||data.cardHeight>220||misplaced||data.overlap||data.overflow)failures.push(results.at(-1));
  }
  const mobile=[];
  for(const [width,height] of [[320,568],[390,844],[597,840],[800,1100]]){
    await page.setViewportSize({width,height});
    for(const [path,selector] of [['/','.stats-grid'],['/inventory','.inv-hub-bar'],['/pos','.pos-workspace']]){
      await page.goto(origin+'/#'+path);await page.locator(selector).first().waitFor();await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
      const data=await page.evaluate(({selector,path})=>{const el=document.querySelector(selector),b=el.getBoundingClientRect();const first=el.querySelector('.stat-card');return {width:b.width,height:b.height,statWidth:first?.getBoundingClientRect().width,statHeight:first?.getBoundingClientRect().height,overflow:document.querySelector('.page-content').scrollWidth>document.querySelector('.page-content').clientWidth+2,columns:path==='/pos'?getComputedStyle(document.querySelector('.pos-products-grid')).gridTemplateColumns.split(' ').length:null};},{selector,path});
      mobile.push({width,height,path,...data});
      if(data.overflow||(path==='/inventory'&&data.height>145)||(path==='/'&&(data.statWidth>210||data.statHeight>125))||(path==='/pos'&&data.columns!==(width<600?1:2)))failures.push(mobile.at(-1));
    }
  }
  if(failures.length)throw Error(JSON.stringify(failures));
  return {pos:results,mobileLayouts:mobile.length,checks:'four columns with desktop navigation collapsed, two tablet columns, one phone column, checkout below tablets/phones, bounded desktop checkout, no action overlap',failures};
}
