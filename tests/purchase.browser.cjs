// Execute with playwright-cli run-code --filename=tests/purchase.browser.cjs
// against a local Vite server. Uses isolated API fixtures, never real Auth/data.
async page => {
  const appUrl=new URL(page.url()).origin;
  const userId='aa000000-0000-4000-8000-000000000001';
  const tenant='aa000000-0000-4000-8000-000000000002';
  const plant='aa000000-0000-4000-8000-000000000003';
  const brand='aa000000-0000-4000-8000-000000000004';
  const sku='aa000000-0000-4000-8000-000000000005';
  const truck='aa000000-0000-4000-8000-000000000006';
  const now=new Date().toISOString();
  const user={ id:userId,aud:'authenticated',role:'authenticated',email:'purchase-ui@example.invalid',app_metadata:{provider:'email'},user_metadata:{},created_at:now };
  const payload=btoa(JSON.stringify({sub:userId,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','').replaceAll('+','-').replaceAll('/','_');
  const token='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'+payload+'.Zml4dHVyZQ';
  await page.context().addInitScript(({user,token})=>{
    localStorage.setItem('lpg-theme','light');
    localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token',JSON.stringify({access_token:token,refresh_token:'fixture-refresh',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user}));
    localStorage.setItem('sb-127.0.0.1:54321-auth-token',localStorage.getItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token'));
  },{user,token});
  const purchases=[];
  const history=new Map();
  const transits=[];
  let emptyAvailable=20;
  const calls=[];
  let purchasePageLimit=6;
  const activityRequests=[];
  let role='manage';
  let failDispatch=false;
  let failActivity=false;
  function recalculate(p) {
    p.subtotal=p.items.reduce((sum,i)=>sum+i.billed_quantity*i.unit_price,0);
    p.company_payable=p.subtotal-p.commission;
    p.total_cost=p.company_payable+p.transport_cost+p.labour_cost;
  }
  function record(p,action,details={}) {
    history.set(p.purchase_id,[...(history.get(p.purchase_id)||[]),{activity_id:crypto.randomUUID(),action,details,actor_name:'Purchase Operator',created_at:new Date().toISOString()}]);
  }
  await page.route('**/auth/v1/**',route=>route.fulfill({json:user}));

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
    const request=route.request();
    const path=new URL(request.url()).pathname.split('/').pop();
    const params=request.method()==='POST'?request.postDataJSON():{};
    let data=[];
    switch(path) {
      case 'user_profiles': data=[{tenant_id:tenant,email:user.email,full_name:'Purchase Operator',tenants:{business_name:'Purchase UI Verification'}}]; break;
      case 'get_my_preferences': data={theme:null}; break;
      case 'get_business_catalogs': data={roles:['Owner','Manager','Salesman','Driver','Helper','General Staff'].map((name,i)=>({id:String(i),name,active:true,system:true,assigned:0})),weights:[5,12,25,35].map(size_kg=>({size_kg,active:true,assigned:0}))}; break;
      case 'get_my_permissions': data=role==='manage'?['purchases:view','purchases:manage','logistics:view','logistics:manage','inventory:view','dashboard:view']:['purchases:view']; break;
      case 'wallets': data=[{type:'dealership',balance:-1703906}]; break;
      case 'list_purchases': throw Error('Unbounded purchase read');
      case 'get_purchase_directory': purchasePageLimit=params.p_limit; data=purchasePage(params); break;
      case 'get_purchase_overview': data=purchaseOverview(); break;
      case 'get_purchases_by_ids': data=purchases.filter(p=>params.p_ids.includes(p.purchase_id)); break;
      case 'get_purchase_settlement': {
        const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);
        data={total:p.total_cost,paid:p.transport_funded||0,due:p.total_cost-(p.transport_funded||0),refund_due:0,refunded:0,financial_closed_at:null,can_cancel:true,financial_locked:false,obligations:[],payment_count:0,payments:[]};break;
      }
      case 'list_transits': data=transits; break;
      case 'list_gas_plants': data=[{plant_id:plant,plant_name:'Meghna Filling Plant',brand_id:brand,brand_name:'Beximco LPG',location:'Narayanganj',is_active:true}]; break;
      case 'list_trucks': data=[{truck_id:truck,name:'Dhaka Delivery Truck',serial_no:'Dhaka Metro 11-4520',status:purchases.some(p=>p.status==='in_transit')||transits.some(t=>t.status==='active')?'going':'idle',capacity:100}]; break;
      case 'items': data=[{item_id:sku,brand_id:brand,brand:'Beximco LPG',size_kg:12,mouth_size:'22mm',empty_quantity:emptyAvailable,lpg_brands:{brand_id:brand,brand_name:'Beximco LPG'}},
        {item_id:'second-sku',brand_id:brand,brand:'Beximco LPG',size_kg:25,mouth_size:'22mm',empty_quantity:0,lpg_brands:{brand_name:'Beximco LPG'}},
        {item_id:'other-sku',brand_id:'other-company',brand:'Other company',size_kg:12,mouth_size:'22mm',empty_quantity:10}]; break;
      case 'get_purchase_activity': {
        if(failActivity){await route.fulfill({status:503,json:{message:'Activity temporarily unavailable'}});return;}
        const url=new URL(request.url());
        const offset=Number(url.searchParams.get('offset')||0), limit=Number(url.searchParams.get('limit')||1000);
        activityRequests.push({offset,limit});
        data=(history.get(params.p_purchase_id)||[]).slice(offset,offset+limit);break;
      }
      case 'create_purchase': {
        calls.push(path);
        const d=params.p_payload;
        const p={...d,purchase_id:crypto.randomUUID(),brand_id:brand,company_name:'Beximco LPG',plant_name:'Meghna Filling Plant',truck_name:d.truck_id?'Dhaka Delivery Truck':null,status:'created',payment_status:'unpaid',created_at:new Date(Date.parse(now)+purchases.length*1000).toISOString(),dispatched_at:null,received_at:null,paid_at:null,receipt_notes:null,legacy_record:false,revision:1,items:[]};
        purchases.unshift(p); record(p,'created');recalculate(p);data={purchase_id:p.purchase_id};break;
      }
      case 'update_purchase': {
        calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);const d=params.p_payload;
        const before=structuredClone(p), saved=p.items;
        Object.assign(p,d);p.truck_name=p.truck_id?'Dhaka Delivery Truck':null;
        if(d.items)p.items=d.items.map(i=>{
          const old=saved.find(item=>item.purchase_item_id===i.purchase_item_id);
          const billed=p.status==='created'?i.quantity:old?.billed_quantity??i.quantity;
          return {...i,purchase_item_id:i.purchase_item_id||crypto.randomUUID(),brand_name:'Beximco LPG',size_kg:12,mouth_size:'22mm',received_quantity:old?.received_quantity??null,billed_quantity:billed,line_total:billed*i.unit_price};
        });
        p.revision++;recalculate(p);record(p,'updated',{before,after:structuredClone(p),items:structuredClone(p.items)});data={};break;
      }
      case 'dispatch_purchase': {
        calls.push(path);
        if(failDispatch){failDispatch=false;await route.fulfill({status:400,json:{message:'Not enough empty cylinders',code:'P0001',details:JSON.stringify([{item_id:sku,product:'Beximco LPG 12 kg 22mm',required:4,available:2,missing:2}])}});return;}
        const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);p.status='in_transit';p.dispatched_at=now;p.revision++;record(p,'dispatched',{empty_cylinders:p.items.reduce((s,i)=>s+i.empty_dispatched,0)});break;
      }
      case 'receive_purchase': {
        calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);
        for(const i of p.items)i.received_quantity=i.quantity;
        p.status='received';p.received_at=now;p.receipt_notes='';p.revision++;recalculate(p);record(p,'received',{notes:p.receipt_notes});break;
      }
      case 'create_custom_transit': { const d=params.p_payload; transits.unshift({tenant_id:tenant,transit_id:crypto.randomUUID(),truck_id:d.truck_id,truck_name:'Dhaka Delivery Truck',purchase_id:null,status:'active',transport_fee:d.fee,client_name:d.client_name,destination:d.destination,description:d.description,driver_cost:0,helper_cost:0,oil_cost:0,others_cost:0,additional_costs:[],total_cost:0,revision:1,closed_at:null,created_at:now,updated_at:now});break; }
      case 'save_transit_costs': {const t=transits.find(t=>t.transit_id===params.p_transit_id);Object.assign(t,params.p_costs);t.total_cost=t.driver_cost+t.helper_cost+t.oil_cost+t.others_cost+t.additional_costs.reduce((s,c)=>s+c.amount,0);t.revision++;break;}
      case 'transition_transit': {const t=transits.find(t=>t.transit_id===params.p_transit_id);if(params.p_action==='close')t.closed_at=now;else t.status=params.p_action==='complete'?'completed':'cancelled';t.revision++;break;}
      default: throw new Error('Unexpected fixture endpoint '+path);
    }
    await route.fulfill({json:data});
  });
  await page.setViewportSize({width:1440,height:1000});
  // A hash navigation alone does not execute the session init script.
  await page.reload();
  await page.goto(`${appUrl}/#/purchases`);
  const check=async(ok,label)=>{if(!ok)throw new Error('FAIL: '+label);};
  const openPurchase=async()=>{await page.locator('.purchase-card').first().click();};
  const selectPlant=async()=>{
    const input=page.getByRole('combobox',{name:'Destination plant'});
    await input.selectOption(plant);
  };
  async function createPlantOnly() {
    const beforeCount=purchases.length;
    // Rapid scripted mutations stack hover-paused toasts over the header action.
    // Move off the toast area and wait for normal dismissal before the next order.
    await page.mouse.move(0,0);
    await page.waitForFunction(()=>!document.querySelector('[data-rht-toaster] [role="status"]'),null,{timeout:15000});
    await page.getByRole('button',{name:'New Purchase',exact:true}).click();
    await selectPlant();
    await page.getByRole('dialog',{name:'New purchase',exact:true}).getByRole('button',{name:'Create purchase',exact:true}).click();
    await check(purchases.length===beforeCount,'creation waits for confirmation');
    await page.getByRole('dialog',{name:'Create this purchase?',exact:true}).getByRole('button',{name:'Create purchase',exact:true}).click();
    await page.getByRole('dialog',{name:'New purchase',exact:true}).waitFor({state:'hidden'});
  }
  await createPlantOnly();
  await openPurchase();
  let details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('combobox',{name:'Truck (optional until dispatch)'}).selectOption(truck);
  await details.getByRole('button',{name:'Add product',exact:true}).click();
  let line=details.locator('article').first();
  await line.getByRole('combobox').selectOption(sku);
  await line.getByLabel('Expected refills',{exact:true}).fill('21');
  await line.getByLabel('Unit price (Tk)',{exact:true}).fill('100');
  await check(await line.getByText('Only 20 empties available',{exact:true}).isVisible(),'inline shortage is visible');
  await check(await line.locator('[aria-invalid=true]').count()===1,'shortage input is marked invalid');
  await details.getByRole('button',{name:'Add product',exact:true}).click();
  let second=details.locator('article').nth(1);
  await second.getByRole('combobox').selectOption('second-sku');
  await second.getByLabel('Expected refills',{exact:true}).fill('3');
  await details.getByRole('button',{name:'Save changes',exact:true}).click();
  const warning=page.getByRole('dialog',{name:'Not enough empty bottles',exact:true});
  await warning.waitFor();
  await check(await warning.locator('li').count()===2,'all shortages appear together');
  await check(await details.count()===1,'purchase stays mounted underneath warning');
  await page.screenshot({path:'.temp/purchase-verification/shortages-desktop.png'});
  await warning.getByRole('button',{name:'Okay',exact:true}).click();
  await check(await line.getByLabel('Expected refills',{exact:true}).inputValue()==='21','warning preserves edits');
  await second.getByRole('button',{name:'Remove product 2',exact:true}).click();
  await line.getByLabel('Expected refills',{exact:true}).fill('4');
  await details.getByLabel('Commission (Tk)',{exact:true}).fill('50');
  await details.getByLabel('Transport cost (Tk)',{exact:true}).fill('20');
  await details.getByLabel('Labour cost (Tk)',{exact:true}).fill('10');
  await details.getByRole('button',{name:'Save changes',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('dialog form button[type=submit]')?.disabled);
  await check(await details.isVisible(),'save keeps purchase open');
  await line.getByLabel('Unit price (Tk)',{exact:true}).fill('110');
  await details.getByRole('button',{name:'Save changes',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('dialog form button[type=submit]')?.disabled);
  await check(purchases[0].items[0].unit_price===110,'second save uses current line IDs and revision');
  for(let i=0;i<10;i++) record(purchases[0],'updated',{
    before:{commission:i,notes:'Previous note'},after:{commission:i+1,notes:'Shipment note '+i},items:structuredClone(purchases[0].items),
  });
  await details.getByRole('button',{name:'Close',exact:true}).click();
  // The extra fixture events bypass mutations, so start with a fresh query cache.
  await page.reload();
  await page.getByRole('heading',{name:'Purchases',exact:true}).waitFor();
  await openPurchase();
  const activity=details.getByRole('region',{name:'Activity history',exact:true});
  await activity.getByText('Page 1',{exact:true}).waitFor();
  await page.waitForFunction(()=>document.querySelectorAll('.purchase-activity > li').length===6);
  await check(await activity.getByText(/Commission: Tk 0 → Tk 50.00/).count()===1,'history explains financial edit');
  await check(await activity.getByText(/price: Tk 100.00 → Tk 110.00/).count()===1,'history explains product price edit');
  await check(await activity.getByRole('button',{name:'Previous page',exact:true}).isDisabled(),'first history page disables previous');
  failActivity=true;
  await activity.getByRole('button',{name:'Next page',exact:true}).click();
  await activity.getByRole('alert').waitFor({timeout:20000});
  await check(await activity.getByRole('button',{name:'Next page',exact:true}).isDisabled(),'failed history page blocks next');
  failActivity=false;
  await activity.getByRole('button',{name:'Retry',exact:true}).click();
  await activity.getByText('Page 2',{exact:true}).waitFor();
  await page.waitForFunction(()=>document.querySelectorAll('.purchase-activity > li').length===6);
  await check(activityRequests.some(r=>r.offset===6&&r.limit===7),'history requests a bounded second page');
  await activity.getByRole('button',{name:'Next page',exact:true}).click();
  await page.waitForFunction(()=>document.querySelectorAll('.purchase-activity > li').length===1);
  await check(await activity.getByRole('button',{name:'Next page',exact:true}).isDisabled(),'last history page disables next');
  await activity.getByRole('button',{name:'Previous page',exact:true}).click();
  await activity.getByRole('button',{name:'Previous page',exact:true}).click();
  await page.waitForFunction(()=>document.querySelectorAll('.purchase-activity > li').length===6);
  await activity.scrollIntoViewIfNeeded();
  await page.screenshot({path:'.temp/purchase-verification/history-desktop.png'});
  await page.evaluate(()=>document.documentElement.dataset.theme='dark');
  await page.screenshot({path:'.temp/purchase-verification/history-desktop-dark.png'});
  await page.evaluate(()=>document.documentElement.dataset.theme='light');
  for(const width of [320,390,768,1366]) {
    await page.setViewportSize({width,height:844});
    await check(await details.evaluate(el=>el.scrollWidth<=el.clientWidth),'purchase modal fits '+width);
    await check(await activity.evaluate(el=>el.scrollWidth<=el.clientWidth),'history fits '+width);
    await check(await details.evaluate(el=>{
      const footer=el.querySelector('.purchase-details-footer'),cancel=footer.querySelector('.purchase-danger-action');
      return Math.abs(cancel.getBoundingClientRect().left-footer.getBoundingClientRect().left-parseFloat(getComputedStyle(footer).paddingLeft))<2;
    }),'cancel purchase stays at left corner '+width);
    if(width===390) {
      await activity.scrollIntoViewIfNeeded();
      await page.screenshot({path:'.temp/purchase-verification/history-mobile.png'});
    }
  }
  await page.screenshot({path:'.temp/purchase-verification/edit-desktop.png'});
  failDispatch=true;
  await details.getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await page.getByRole('dialog',{name:'Dispatch this truck?',exact:true}).getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await warning.waitFor();
  await check(await warning.getByText('Need 2 more bottles. Available: 2. Required: 4.',{exact:true}).isVisible(),'server stock race shows structured warning');
  await warning.getByRole('button',{name:'Okay',exact:true}).click();
  await check(await details.isVisible(),'server warning preserves purchase modal');
  await details.getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await page.getByRole('dialog',{name:'Dispatch this truck?',exact:true}).getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await details.getByRole('button',{name:'Record payment',exact:true}).waitFor();
  await details.getByRole('button',{name:'Receive shipment',exact:true}).waitFor();
  return 'PASS: plant-only drafts, grouped shortages, retained edits, activity paging, responsive details, dispatch race recovery and current independent settlement actions';
}
