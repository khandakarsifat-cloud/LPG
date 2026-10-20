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
    localStorage.setItem('sb-api-auth-token',JSON.stringify({access_token:token,refresh_token:'fixture-refresh',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user}));
    localStorage.setItem('sb-127-auth-token',localStorage.getItem('sb-api-auth-token'));
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
      case 'get_my_permissions': data=role==='manage'?['purchases:view','purchases:manage','logistics:view','logistics:manage','inventory:view','dashboard:view']:['purchases:view']; break;
      case 'wallets': data=[{type:'dealership',balance:-1703906}]; break;
      case 'list_purchases': throw Error('Unbounded purchase read');
      case 'get_purchase_directory': purchasePageLimit=params.p_limit; data=purchasePage(params); break;
      case 'get_purchase_overview': data=purchaseOverview(); break;
      case 'get_purchases_by_ids': data=purchases.filter(p=>params.p_ids.includes(p.purchase_id)); break;
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
      case 'pay_purchase': { calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);p.payment_status='paid';p.paid_at=now;p.revision++;record(p,'paid',{total_cost:p.total_cost});break; }
      case 'receive_purchase': {
        calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);
        for(const i of p.items)i.received_quantity=i.quantity;
        p.status='received';p.received_at=now;p.receipt_notes='';p.revision++;recalculate(p);record(p,'received',{notes:p.receipt_notes});break;
      }
      case 'cancel_purchase': { const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);p.status='cancelled';p.revision++;record(p,'cancelled');break; }
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
  await check(await activity.getByRole('button',{name:'Previous',exact:true}).isDisabled(),'first history page disables previous');
  failActivity=true;
  await activity.getByRole('button',{name:'Next',exact:true}).click();
  await activity.getByRole('alert').waitFor({timeout:20000});
  await check(await activity.getByRole('button',{name:'Next',exact:true}).isDisabled(),'failed history page blocks next');
  failActivity=false;
  await activity.getByRole('button',{name:'Retry',exact:true}).click();
  await activity.getByText('Page 2',{exact:true}).waitFor();
  await page.waitForFunction(()=>document.querySelectorAll('.purchase-activity > li').length===6);
  await check(activityRequests.some(r=>r.offset===6&&r.limit===7),'history requests a bounded second page');
  await activity.getByRole('button',{name:'Next',exact:true}).click();
  await page.waitForFunction(()=>document.querySelectorAll('.purchase-activity > li').length===1);
  await check(await activity.getByRole('button',{name:'Next',exact:true}).isDisabled(),'last history page disables next');
  await activity.getByRole('button',{name:'Previous',exact:true}).click();
  await activity.getByRole('button',{name:'Previous',exact:true}).click();
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
  await details.getByRole('button',{name:'Record full payment',exact:true}).waitFor();
  await details.getByRole('button',{name:'Record full payment',exact:true}).click();
  await page.getByRole('dialog',{name:'Record full payment?',exact:true}).getByRole('button',{name:'Record full payment',exact:true}).click();
  await page.waitForFunction(()=>!Array.from(document.querySelectorAll('dialog')).some(d=>d.textContent.includes('Record full payment?')));
  await check(await details.isVisible(),'payment keeps purchase open');
  await details.getByRole('button',{name:'Receive shipment',exact:true}).click();
  const receipt=page.getByRole('dialog',{name:'Receive this shipment?',exact:true});
  await check(await receipt.locator('input').count()===0,'receipt has no quantity inputs');
  await receipt.getByRole('button',{name:'Receive shipment',exact:true}).click();
  const completed=page.getByRole('dialog',{name:'Completed purchase',exact:true});
  await completed.waitFor();
  await check(purchases[0].items[0].received_quantity===4,'receipt uses expected quantity');
  await check(await completed.getByRole('heading',{name:'Activity history',exact:true}).isVisible(),'completed purchase retains history');
  await completed.getByRole('button',{name:'Cancel purchase',exact:true}).click();
  await page.getByRole('dialog',{name:'Cancel this purchase?',exact:true}).getByRole('button',{name:'Go back',exact:true}).click();
  await completed.getByRole('button',{name:'Close',exact:true}).click();
  const settlePurchases=async()=>{if(!await page.locator('#purchase-search').count())return;await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));await page.waitForFunction(()=>document.querySelector('.purchases-grid')?.getAttribute('aria-busy')==='false');};
  // Exercise the list with enough orders to overflow a short desktop viewport.
  for(let i=0;i<10;i++) purchases.push({...purchases[0],purchase_id:crypto.randomUUID(),plant_name:`Delivery plant ${i+1}`,
    created_at:`2026-10-${String(i+1).padStart(2,'0')}T12:00:00Z`,payment_status:'paid',subtotal:1000+i*100,company_payable:1000+i*100,total_cost:1000+i*100,
    company_name:i%2===0?'Jamuna Gas':'Bashundhara LPG',truck_name:i%2===0?'Ashok Leyland':'JAC',
    items:purchases[0].items.map(item=>({...item,unit_price:(1000+i*100)/2,line_total:1000+i*100,brand_name:i%2===0?'Jamuna Gas':'Bashundhara LPG'}))});
  await page.reload();
  await page.getByRole('heading',{name:'Purchases',exact:true}).waitFor();
  await page.setViewportSize({width:1366,height:646});
  await check(await page.locator('.topbar-wallet').evaluate(el=>el.classList.contains('negative')),'negative wallet has deficit styling');
  await check(await page.locator('#purchase-search').evaluate(el=>parseFloat(getComputedStyle(el).paddingLeft)>=32),'search text clears its icon');
  await check(await page.locator('.purchases-grid').evaluate(el=>el.scrollHeight<=el.clientHeight),'purchase grid does not create a nested scrollbar');
  await page.locator('.purchase-card').last().scrollIntoViewIfNeeded();
  await check(await page.locator('.purchase-card').last().isVisible(),'last purchase remains reachable');
  await page.locator('.page-content').evaluate(el=>el.scrollTop=0);
  await page.screenshot({path:'.temp/purchase-verification/list-desktop.png'});
  await page.getByLabel('Search purchases',{exact:true}).fill('not-a-plant');
  await settlePurchases();
  await page.getByRole('button',{name:'Clear filters',exact:true}).first().click();
  await settlePurchases();
  await check(await page.locator('.purchase-card').count()===Math.min(purchasePageLimit,purchases.length)&&(await page.locator('.purchase-results-heading').textContent()).includes(String(purchases.length)),'clear filters restores the unfiltered first page and full count');
  const searchControl=page.getByLabel('Search purchases',{exact:true});
  await searchControl.fill('  JAMUNA   ashok 22mm 12KG  ');
  await settlePurchases();
  await check(await page.locator('.purchase-card').count()===Math.min(purchasePageLimit,5)&&(await page.locator('.purchase-results-heading').textContent()).includes('5'),'AND search matches company, vehicle and specifications');
  await page.getByRole('combobox',{name:'Purchase status',exact:true}).selectOption('received');
  await settlePurchases();
  await page.getByRole('combobox',{name:'Payment status',exact:true}).selectOption('paid');
  await settlePurchases();
  await page.getByLabel('From',{exact:true}).fill('2026-10-03');
  await settlePurchases();
  await page.getByLabel('To',{exact:true}).fill('2026-10-07');
  await settlePurchases();
  await check(await page.locator('.purchase-card').count()===Math.min(purchasePageLimit,3)&&(await page.locator('.purchase-results-heading').textContent()).includes('3'),'search combines with status, payment and inclusive dates');
  await searchControl.fill('jamuna ashok, bashundhara 12kg');
  await settlePurchases();
  await check(await page.locator('.purchase-card').count()===Math.min(purchasePageLimit,5)&&(await page.locator('.purchase-results-heading').textContent()).includes('5'),'OR groups stay within active filters');
  await page.getByRole('combobox',{name:'Sort by',exact:true}).selectOption('amount_desc');
  await settlePurchases();
  await check(await page.locator('.purchase-card').first().getAttribute('data-purchase-id')===purchases.find(p=>p.plant_name==='Delivery plant 7').purchase_id,'highest total first');
  await page.getByRole('combobox',{name:'Sort by',exact:true}).selectOption('amount_asc');
  await settlePurchases();
  await check(await page.locator('.purchase-card').first().getAttribute('data-purchase-id')===purchases.find(p=>p.plant_name==='Delivery plant 3').purchase_id,'lowest total first');
  await page.getByRole('combobox',{name:'Sort by',exact:true}).selectOption('date_desc');
  await settlePurchases();
  await check(await page.locator('.purchase-card').first().getAttribute('data-purchase-id')===purchases.find(p=>p.plant_name==='Delivery plant 7').purchase_id,'newest date first');
  await page.getByRole('combobox',{name:'Sort by',exact:true}).selectOption('date_asc');
  await settlePurchases();
  await check(await page.locator('.purchase-card').first().getAttribute('data-purchase-id')===purchases.find(p=>p.plant_name==='Delivery plant 3').purchase_id,'oldest date first');
  await page.getByRole('combobox',{name:'Payment status',exact:true}).selectOption('unpaid');
  await settlePurchases();
  await check(await page.getByText('No purchases match these filters.',{exact:true}).isVisible(),'OR search cannot bypass payment filter');
  await page.getByRole('button',{name:'Clear filters',exact:true}).first().click();
  await settlePurchases();
  await check(await page.locator('.purchase-card').count()===Math.min(purchasePageLimit,purchases.length),'reset clears search, statuses, dates and sort on the first page');
  await check(await page.locator('.topbar h1').innerText()==='Purchases','page name replaces header search');
  await check(await page.getByRole('textbox',{name:'Search workspace'}).count()===0,'workspace search removed');
  await check(await page.locator('.purchase-card .purchase-items-count, .purchase-card-action').count()===0,'cards omit product count labels and summary links');
  await check(await page.locator('.purchase-card').first().locator('.purchase-item-pill').count()===purchases[0].items.length,'cards show their product list');
  await check(await page.locator('.purchase-card').first().innerText().then(text=>!text.includes('Meghna Filling Plant')&&!text.includes('Company payable')),'cards omit plant name and separate company payable');
  await check(await page.locator('.purchase-card .purchase-card-footer').first().innerText().then(text=>text.includes('Total purchase cost')),'card shows one total row');
  const dateInput=page.getByLabel('From',{exact:true});
  await dateInput.fill('2026-10-05');
  await settlePurchases();
  await page.getByRole('button',{name:'Choose date: From',exact:true}).click();
  const calendar=page.getByRole('dialog',{name:'Choose date: From',exact:true});
  await calendar.waitFor();
  await calendar.getByRole('button',{name:'Monday, October 5, 2026',exact:true}).press('ArrowRight');
  await page.keyboard.press('Enter');
  await check(await dateInput.inputValue()==='2026-10-06','calendar keyboard selects a date and updates filter');
  await page.getByRole('button',{name:'Choose date: To',exact:true}).click();
  const toCalendar=page.getByRole('dialog',{name:'Choose date: To',exact:true});
  await toCalendar.getByRole('combobox',{name:'Calendar month',exact:true}).selectOption('9');
  await settlePurchases();
  await toCalendar.getByRole('spinbutton',{name:'Calendar year',exact:true}).fill('2026');
  await settlePurchases();
  await check(await toCalendar.getByRole('button',{name:'Monday, October 5, 2026',exact:true}).getAttribute('aria-disabled')==='true','calendar respects date range minimum');
  await page.screenshot({path:'.temp/purchase-verification/calendar-desktop.png'});
  await toCalendar.getByRole('button',{name:'Clear',exact:true}).click();
  await page.getByRole('button',{name:'Clear filters',exact:true}).first().click();
  await settlePurchases();
  await page.getByRole('combobox',{name:'Purchase status',exact:true}).click();
  await page.screenshot({path:'.temp/purchase-verification/dropdown-desktop.png'});
  await page.keyboard.press('Escape');
  await page.getByRole('button',{name:'Account: Purchase Operator',exact:true}).click();
  await check(await page.getByRole('menuitem',{name:'Sign Out',exact:true}).isVisible(),'sidebar account opens signout');
  await page.screenshot({path:'.temp/purchase-verification/sidebar-account.png'});
  await page.keyboard.press('Escape');
  await check(await page.locator('.sidebar-tenant-role').innerText()==='Purchase Operator','account name is below business name');
  await page.setViewportSize({width:1180,height:760});
  await page.getByRole('button',{name:'Collapse sidebar',exact:true}).click();
  await page.getByRole('button',{name:'Account: Purchase Operator',exact:true}).click();
  await check(await page.getByRole('menu').evaluate(el=>{
    const box=el.getBoundingClientRect();
    return document.elementFromPoint(box.right-5,box.top+5)?.closest('[role=menu]')===el;
  }),'collapsed sidebar account menu is not clipped');
  await page.keyboard.press('Escape');
  // Exercise both sidebar states and text scaling without changing business data.
  for(const collapsed of [true,false]) {
    if(!collapsed) await page.getByRole('button',{name:'Expand sidebar',exact:true}).click();
    for(const width of [1024,1180,1250,1366,1600,2560]) {
      await page.setViewportSize({width,height:800});
      await page.evaluate(async()=>{await Promise.all(document.getAnimations().map(a=>a.finished.catch(()=>{})));});
      await check(await page.locator('.topbar').evaluate(el=>{
        const title=el.querySelector('h1').getBoundingClientRect();
        const wallet=el.querySelector('.topbar-wallet').getBoundingClientRect();
        return title.right<=wallet.left && wallet.right<=el.getBoundingClientRect().right+1;
      }),`title and wallet fit at ${width}px, sidebar collapsed=${collapsed}`);
    }
  }
  await page.setViewportSize({width:1180,height:760});
  await page.getByRole('button',{name:'Collapse sidebar',exact:true}).click();
  await page.evaluate(()=>document.documentElement.style.fontSize='20px');
  await page.evaluate(async()=>{await Promise.all(document.getAnimations().map(a=>a.finished.catch(()=>{})));});
  await check(await page.locator('.page-content').evaluate(el=>el.scrollWidth<=el.clientWidth),'tablet header has no overflow with 125 percent text');
  await check(await page.locator('.topbar').evaluate(el=>{
    const title=el.querySelector('h1').getBoundingClientRect();
    const wallet=el.querySelector('.topbar-wallet').getBoundingClientRect();
    return Math.abs((title.top+title.bottom)/2-(wallet.top+wallet.bottom)/2)<12;
  }),'enlarged tablet text keeps wallet on the heading row');
  await page.screenshot({path:'.temp/purchase-verification/header-tablet-large-text.png'});
  await page.evaluate(()=>document.documentElement.style.fontSize='');
  await page.getByRole('button',{name:'Expand sidebar',exact:true}).click();
  for(const width of [320,390,768,1024,1366]) {
    await page.setViewportSize({width,height:844});
    await page.evaluate(async()=>{await Promise.all(document.getAnimations().map(animation=>animation.finished.catch(()=>{})));});
    await check(await page.locator('.page-content').evaluate(el=>el.scrollWidth<=el.clientWidth),`purchase page has no horizontal overflow at ${width}px`);
    await check(await page.getByRole('button',{name:'Switch to dark theme'}).isVisible(),`theme control available at ${width}px`);
    if(width<=1024) {
      const menuBtn=page.getByRole('button',{name:'Open navigation menu',exact:true});
      await check(await menuBtn.isVisible(),`menu button available at ${width}px`);
      await menuBtn.click();
      await check(await page.locator('.sidebar-account .user-menu-trigger').isVisible(),`sidebar account available in drawer at ${width}px`);
      await page.getByRole('complementary').getByRole('button',{name:'Close navigation menu',exact:true}).click();
    } else {
      await check(await page.locator('.sidebar-account .user-menu-trigger').isVisible(),`sidebar account available at ${width}px`);
    }
    await check(await page.locator('.topbar').evaluate(el=>el.scrollWidth<=el.clientWidth),`topbar fits at ${width}px`);
  }
  await page.setViewportSize({width:390,height:844});
  await page.screenshot({path:'.temp/purchase-verification/list-mobile.png'});
  await page.getByRole('button',{name:'Switch to dark theme'}).click();
  await page.evaluate(async()=>{await Promise.all(document.getAnimations().map(animation=>animation.finished.catch(()=>{})));});
  await page.screenshot({path:'.temp/purchase-verification/list-mobile-dark.png'});
  await page.setViewportSize({width:1366,height:646});
  await page.screenshot({path:'.temp/purchase-verification/list-desktop-dark.png'});
  await page.getByRole('button',{name:'Switch to light theme'}).click();
  await page.goto(`${appUrl}/#/logistics`);
  await page.getByRole('button',{name:'Transits & Trips',exact:true}).click();
  await page.getByRole('button',{name:'Add custom transit',exact:true}).click();
  const custom=page.getByRole('dialog',{name:'New custom transit',exact:true});
  await check(await custom.getByRole('button',{name:'Start transit',exact:true}).isDisabled(),'custom transit requires client and truck');
  await custom.getByLabel('Client name *',{exact:true}).fill('Rahim Traders');
  await settlePurchases();
  await custom.getByRole('combobox',{name:'Truck *',exact:true}).selectOption(truck);
  await settlePurchases();
  await custom.getByLabel('Destination',{exact:true}).fill('Dhaka');
  await settlePurchases();
  await custom.getByLabel('Description',{exact:true}).fill('Cylinder delivery');
  await settlePurchases();
  await custom.getByLabel('Client transport fee (Tk)',{exact:true}).fill('1000.50');
  await settlePurchases();
  await custom.getByRole('button',{name:'Start transit',exact:true}).click();
  await page.locator('.transit-card').first().click();
  const transit=page.getByRole('dialog',{name:'Transit details',exact:true});
  await check(await transit.locator('select').count()===0,'transit has workflow buttons and no status dropdown');
  await transit.getByLabel('Driver cost (Tk)',{exact:true}).fill('100.50');
  await settlePurchases();
  await transit.getByLabel('Others cost (Tk)',{exact:true}).fill('25');
  await settlePurchases();
  await transit.getByRole('button',{name:'Add cost',exact:true}).click();
  await transit.getByLabel('Cost name',{exact:true}).fill('Toll');
  await settlePurchases();
  await transit.getByLabel('Amount (Tk)',{exact:true}).fill('10.25');
  await settlePurchases();
  await transit.getByRole('button',{name:'Save changes',exact:true}).click();
  await page.waitForFunction(()=>Array.from(document.querySelectorAll('dialog button')).some(b=>b.textContent.includes('Save changes')&&b.disabled));
  await check(await transit.isVisible(),'transit stays open after saving');
  await transit.getByRole('button',{name:'Complete transit',exact:true}).click();
  await page.getByRole('dialog',{name:'Complete this transit?',exact:true}).getByRole('button',{name:'Okay',exact:true}).click();
  await transit.getByRole('button',{name:'Close transit',exact:true}).waitFor();
  await check(!(await transit.getByLabel('Others cost (Tk)',{exact:true}).isDisabled()),'completed transit costs remain editable');
  await transit.getByLabel('Others cost (Tk)',{exact:true}).fill('30');
  await settlePurchases();
  await transit.getByRole('button',{name:'Save changes',exact:true}).click();
  await page.waitForFunction(()=>Array.from(document.querySelectorAll('dialog button')).some(b=>b.textContent.includes('Save changes')&&b.disabled));
  for(const width of [320,390,768,1366]) {
    await page.setViewportSize({width,height:844});
    await check(await transit.evaluate(el=>el.scrollWidth<=el.clientWidth),'transit modal fits '+width);
    await page.screenshot({path:'.temp/purchase-verification/transit-'+width+'.png'});
  }
  await transit.getByRole('button',{name:'Close transit',exact:true}).click();
  await page.getByRole('dialog',{name:'Close this transit?',exact:true}).getByRole('button',{name:'Okay',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('dialog fieldset')?.disabled);
  await check(await transit.getByLabel('Others cost (Tk)',{exact:true}).isDisabled(),'confirmed closure locks costs');
  await transit.getByRole('button',{name:'Close',exact:true}).click();
  await page.goto(`${appUrl}/#/purchases`);
  // A view-only account must also have no actions on an unfinished shipment.
  const viewed={...purchases[0],purchase_id:crypto.randomUUID(),status:'in_transit',payment_status:'unpaid',received_at:null,paid_at:null};
  purchases.unshift(viewed);
  role='view';await page.reload();
  await page.getByRole('heading',{name:'Purchases',exact:true}).waitFor();
  await check(await page.getByRole('button',{name:'New Purchase',exact:true}).count()===0,'view-only user has no create action');
  // Equal creation times are sorted by ID; target the unfinished fixture explicitly.
  await page.locator(`[data-purchase-id="${viewed.purchase_id}"]`).click();
  await check(await page.getByRole('button',{name:'Save changes',exact:true}).count()===0,'view-only summary has no mutation actions');
  await check(await page.getByRole('button',{name:'Receive shipment',exact:true}).count()===0,'view-only user cannot receive unfinished shipment');
  await page.getByText('No activity on this page.',{exact:true}).waitFor();
  return 'PASS: history summaries, bounded pagination, first/last page, error/retry and empty history; left-aligned cancellation; retained purchase/transit flows, responsive 320-2560px, themes and permissions (isolated API fixtures).';
}
