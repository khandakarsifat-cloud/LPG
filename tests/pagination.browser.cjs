// Long collections and drafts, using isolated API fixtures only.
async page => {
  const origin = new URL(page.url()).origin;
  const id = n => `bf${n.toString(16).padStart(6,'0')}-0000-4000-8000-000000000001`;
  const tenant=id(1), now=new Date().toISOString();
  const user={id:id(2),aud:'authenticated',role:'authenticated',email:'pages@example.invalid',app_metadata:{},user_metadata:{},created_at:now};
  const payload=btoa(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','').replaceAll('+','-').replaceAll('/','_');
  const token='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'+payload+'.Zml4dHVyZQ';
  await page.context().addInitScript(({user,token})=>{const session=JSON.stringify({access_token:token,refresh_token:'fixture',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user});for(const host of ['127','api','localhost'])localStorage.setItem(`sb-${host}-auth-token`,session);},{user,token});
  let brands=Array.from({length:14},(_,n)=>({tenant_id:tenant,brand_id:id(10+n),brand_name:`Brand ${n+1}`,is_active:true}));
  const items=Array.from({length:30},(_,n)=>({tenant_id:tenant,item_id:id(100+n),brand_id:brands[Math.floor(n/15)].brand_id,brand:brands[Math.floor(n/15)].brand_name,size_kg:5+n%15,mouth_size:'22mm',filled_quantity:100,empty_quantity:100,lpg_brands:brands[Math.floor(n/15)]}));
  const purchaseItems=items.slice(0,7).map((item,n)=>({...item,purchase_item_id:id(300+n),brand_name:brands[0].brand_name,type:'refill',quantity:2,empty_dispatched:2,unit_price:10,billed_quantity:2,received_quantity:null,line_total:20}));
  const purchases=Array.from({length:14},(_,n)=>({purchase_id:id(400+n),plant_id:id(500),plant_name:'Fixture plant',brand_id:brands[0].brand_id,company_name:brands[0].brand_name,truck_id:null,truck_name:null,status:'created',payment_status:'unpaid',created_at:now,dispatched_at:null,received_at:null,paid_at:null,subtotal:140,commission:0,company_payable:140,transport_cost:0,labour_cost:0,total_cost:140,notes:'',receipt_notes:null,revision:1,legacy_record:false,items:structuredClone(purchaseItems)}));
  const trucks=Array.from({length:14},(_,n)=>({truck_id:id(600+n),name:`Truck ${n+1}`,serial_no:`Dhaka ${n+1}`,status:'idle',capacity:100,truck_size:'medium',location:'Dhaka',is_active:true}));
  const transits=Array.from({length:28},(_,n)=>({transit_id:id(700+n),truck_id:trucks[n%14].truck_id,truck_name:trucks[n%14].name,purchase_id:null,status:n<14?'active':'completed',transport_fee:1000,driver_cost:10,helper_cost:10,oil_cost:10,others_cost:10,additional_costs:Array.from({length:7},(_,i)=>({name:`Cost ${i+1}`,amount:10})),total_cost:110,client_name:'Fixture client',destination:'Dhaka',description:'',revision:1,closed_at:null,created_at:now}));
  const employees=Array.from({length:13},(_,n)=>({employee_id:id(800+n),name:`Employee ${n+1}`,address:'Dhaka',current_salary:1000,business_unit:'gas_business',notes:null,is_active:true,created_at:now,updated_at:now,employee_type_id:null,employee_type_name:'Worker',phones:Array.from({length:9},(_,i)=>({phone:`017${String(n*10+i).padStart(8,'0')}`,is_primary:i===0})),primary_phone:'01700000000',payment_count:10}));
  const payments=Array.from({length:10},(_,n)=>({payment_id:id(900+n),employee_id:employees[0].employee_id,employee_name:'Employee 1',category_id:id(950),category_code:'bonus',category_name:'Bonus',category_kind:'bonus',amount:100,payment_date:'2026-10-19',description:'Fixture',salary_year:null,salary_month:null,trip_count:null,created_at:now}));
  const plants=Array.from({length:14},(_,n)=>({plant_id:id(1000+n),plant_name:`Plant ${n+1}`,brand_id:brands[0].brand_id,brand_name:brands[0].brand_name,location:'Dhaka',is_active:true,officer_id:null}));
  const calls=[];
  await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));

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
  await page.route('**/rest/v1/**',async route=>{
    const req=route.request(),url=new URL(req.url()),name=url.pathname.split('/').pop(),args=req.method()==='POST'?req.postDataJSON():{};
    calls.push({name,args});let data=[];
    if(name==='user_profiles')data=[{tenant_id:tenant,full_name:'Page Operator',email:user.email,tenants:{business_name:'Pagination verification'}}];
    else if(name==='get_my_permissions')data=['dashboard:view','pos:sell','sales:view','receipts:print','purchases:view','purchases:manage','inventory:view','inventory:manage','employees:view','employees:manage','payroll:view','payroll:pay','logistics:view','logistics:manage','settings:manage','gas_plants:view','gas_plants:manage'];
    else if(name==='wallets')data=[{type:'dealership',balance:10000}];
    else if(name==='items')data=items;
    else if(name==='list_lpg_brands')data=brands;
    else if(name==='list_trucks')data=trucks;
    else if(name==='list_transits')data=transits;
    else if(name==='list_purchases')throw Error('Unbounded purchase read');
    else if(name==='get_purchase_directory')data=purchasePage(args);
    else if(name==='get_purchase_overview')data=purchaseOverview();
    else if(name==='get_purchases_by_ids')data=purchases.filter(p=>args.p_ids.includes(p.purchase_id));
    else if(name==='list_employees')data=employees;
    else if(name==='list_employee_payments')data=payments;
    else if(name==='list_employee_payment_categories')data=[{category_id:id(950),code:'bonus',name:'Bonus',category_kind:'bonus',is_active:true}];
    else if(name==='list_gas_plants')data=plants;
    else if(name==='update_purchase'){
      const p=purchases.find(p=>p.purchase_id===args.p_purchase_id);Object.assign(p,args.p_payload);p.revision++;p.items=p.items.map((line,n)=>({...items.find(item=>item.item_id===line.item_id),...line,purchase_item_id:line.purchase_item_id||id(1200+n),brand_name:brands[0].brand_name,billed_quantity:line.quantity,received_quantity:null,line_total:line.quantity*line.unit_price}));p.subtotal=p.items.reduce((s,i)=>s+i.line_total,0);p.company_payable=p.subtotal-p.commission;p.total_cost=p.company_payable+p.transport_cost+p.labour_cost;data={};
    } else if(name==='save_transit_costs'){
      const t=transits.find(t=>t.transit_id===args.p_transit_id);t.additional_costs=args.p_additional_costs;t.revision++;data={};
    } else if(name==='set_lpg_brand_order'){brands=args.p_brand_ids.map(id=>brands.find(b=>b.brand_id===id));data=null;}
    return route.fulfill({json:data});
  });
  const check=(value,message)=>{if(!value)throw Error(message);};
  await page.goto(origin+'/?pagination-fixtures=1#/purchases');await page.locator('.purchase-card').first().waitFor();
  await page.waitForFunction(()=>document.querySelector('.purchases-grid')?.getAttribute('aria-busy')==='false');
  const firstPageSize=calls.filter(c=>c.name==='get_purchase_directory').at(-1).args.p_limit;
  check(await page.locator('.purchase-card').count()===Math.min(firstPageSize,purchases.length),'Responsive purchase directory page size');
  check((await page.locator('.purchase-list-summary').textContent()).includes('14'),'Purchase overview must use all pages');
  await page.getByRole('navigation',{name:'purchases pages'}).getByRole('button',{name:'Next page'}).click();
  await page.waitForFunction(()=>document.querySelector('.purchases-grid')?.getAttribute('aria-busy')==='false');
  check(await page.locator('.purchase-card').count()===Math.min(firstPageSize,purchases.length-firstPageSize),'Remaining purchases missing');
  await page.locator('.purchase-card').first().click();
  const purchase=page.getByRole('dialog',{name:'Purchase details',exact:true});await purchase.locator('.purchase-line').first().waitFor();
  await purchase.getByLabel('Expected refills',{exact:true}).first().fill('3');
  await purchase.getByRole('navigation',{name:'product lines pages'}).getByRole('button',{name:'Next page'}).click();
  check(await purchase.locator('.purchase-line').count()===1,'Purchase editor last page missing');
  await purchase.getByRole('navigation',{name:'product lines pages'}).getByRole('button',{name:'Previous page'}).click();
  check(await purchase.getByLabel('Expected refills',{exact:true}).first().inputValue()==='3','Draft quantity lost across pages');
  await purchase.getByRole('button',{name:'Add product',exact:true}).click();
  await purchase.getByLabel('Product 8',{exact:true}).selectOption(items[7].item_id);
  await purchase.getByLabel('Unit price (Tk)',{exact:true}).last().fill('10');
  await purchase.getByRole('button',{name:'Save changes',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('[role=status]')?.textContent?.includes('saved')||!document.querySelector('dialog button[type=submit]')?.textContent?.includes('Saving'));
  const saved=calls.filter(c=>c.name==='update_purchase').at(-1)?.args.p_payload;
  check(saved?.items.length===8&&saved.items[0].quantity===3&&saved.items[7].item_id===items[7].item_id,'Saved purchase must contain all draft pages');
  await purchase.getByRole('button',{name:'Close dialog',exact:true}).click();
  await page.goto(origin+'/#/inventory');await page.locator('.inv-tile:not(.inv-tile-skeleton)').first().waitFor();
  check(await page.locator('.inv-tile').count()===items.length,'Inventory must show the complete catalog');
  check(await page.getByRole('navigation',{name:'products pages'}).count()===0,'Inventory items must not paginate');
  await page.goto(origin+'/#/employees');await page.locator('.employees-table tbody tr').first().waitFor();
  check(await page.locator('.employees-table tbody tr').count()===12,'Employee directory page size');
  await page.getByRole('navigation',{name:'employees pages'}).getByRole('button',{name:'Next page'}).click();
  check(await page.locator('.employees-table tbody tr').count()===1,'Employee second page missing');
  await page.locator('.employees-payment-row').first().waitFor();
  check(await page.locator('.employees-payment-row').count()===6,'Employee payment page size');
  await page.getByRole('navigation',{name:'payments pages'}).getByRole('button',{name:'Next page'}).click();
  check(await page.locator('.employees-payment-row').count()===4,'Employee payment last page missing');
  check((await page.locator('.employees-total-grid').textContent()).includes('1,000'),'Employee yearly totals must include all payment pages');
  await page.goto(origin+'/#/gas-plants');await page.getByRole('navigation',{name:'gas plants pages'}).waitFor();
  await page.getByRole('navigation',{name:'gas plants pages'}).getByRole('button',{name:'Next page'}).click();
  await page.getByText('Plant 14',{exact:true}).waitFor();
  await page.goto(origin+'/#/logistics');await page.getByRole('navigation',{name:'trucks pages'}).waitFor();
  await page.getByRole('navigation',{name:'trucks pages'}).getByRole('button',{name:'Next page'}).click();
  await page.getByText('Truck 14',{exact:true}).waitFor();
  await page.getByRole('button',{name:'Transits & Trips',exact:true}).click();
  await page.getByRole('navigation',{name:'active transits pages'}).waitFor();
  await page.getByRole('navigation',{name:'active transits pages'}).getByRole('button',{name:'Next page'}).click();
  await page.locator('.transit-card').first().click();
  const transit=page.getByRole('dialog',{name:'Transit details',exact:true});
  await transit.getByRole('navigation',{name:'additional costs pages'}).getByRole('button',{name:'Next page'}).click();
  await transit.getByRole('button',{name:'Add cost',exact:true}).click();
  check(await transit.locator('.transit-additional-row').count()===2,'New cost did not stay on its page');
  await transit.getByRole('button',{name:'Close dialog',exact:true}).click();
  await page.goto(origin+'/#/settings');await page.getByRole('button',{name:/LPG Brands/}).click();
  await page.getByRole('navigation',{name:'brands pages'}).waitFor();
  await page.getByRole('button',{name:'Move Brand 12 down',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.brand-order-controls')?.textContent.includes('Position'));
  check(calls.filter(c=>c.name==='set_lpg_brand_order').at(-1)?.args.p_brand_ids.length===14,'Brand reordering must retain the full catalog');
  return 'PASS: long purchase/catalog/employee/payment/plant/truck/transit/brand pages; full financial summaries, cross-page draft save and complete brand order.';
}
