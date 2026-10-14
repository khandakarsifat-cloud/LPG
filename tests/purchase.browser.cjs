// Execute with playwright-cli run-code --filename=tests/purchase.browser.cjs
// against a local Vite server. Uses isolated API fixtures, never real Auth/data.
async page => {
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
    localStorage.setItem('sb-127-auth-token',JSON.stringify({access_token:token,refresh_token:'fixture-refresh',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user}));
  },{user,token});
  const purchases=[];
  const history=new Map();
  const calls=[];
  let role='manage';
  let failDispatch=false;
  function recalculate(p) {
    p.subtotal=p.items.reduce((sum,i)=>sum+i.billed_quantity*i.unit_price,0);
    p.company_payable=p.subtotal-p.commission;
    p.total_cost=p.company_payable+p.transport_cost+p.labour_cost;
  }
  function record(p,action,details={}) {
    history.set(p.purchase_id,[...(history.get(p.purchase_id)||[]),{activity_id:crypto.randomUUID(),action,details,actor_name:'Purchase Operator',created_at:new Date().toISOString()}]);
  }
  await page.route('**/auth/v1/**',route=>route.fulfill({json:user}));
  await page.route('**/rest/v1/**',async route=>{
    const request=route.request();
    const path=new URL(request.url()).pathname.split('/').pop();
    const params=request.method()==='POST'?request.postDataJSON():{};
    let data=[];
    switch(path) {
      case 'user_profiles': data=[{tenant_id:tenant,email:user.email,full_name:'Purchase Operator',tenants:{business_name:'Purchase UI Verification'}}]; break;
      case 'get_my_permissions': data=role==='manage'?['purchases:view','purchases:manage','logistics:view','inventory:view','dashboard:view']:['purchases:view']; break;
      case 'wallets': data=[{type:'dealership',balance:20000}]; break;
      case 'list_purchases': data=purchases; break;
      case 'list_gas_plants': data=[{plant_id:plant,plant_name:'Meghna Filling Plant',brand_id:brand,brand_name:'Beximco LPG',location:'Narayanganj',is_active:true}]; break;
      case 'list_trucks': data=[{truck_id:truck,name:'Dhaka Delivery Truck',serial_no:'Dhaka Metro 11-4520',status:purchases.some(p=>p.status==='in_transit')?'going':'idle',capacity:100}]; break;
      case 'items': data=[{item_id:sku,brand_id:brand,brand:'Beximco LPG',size_kg:12,mouth_size:'22mm',empty_quantity:20,lpg_brands:{brand_id:brand,brand_name:'Beximco LPG'}},
        {item_id:'other-sku',brand_id:'other-company',brand:'Other company',size_kg:12,mouth_size:'22mm',empty_quantity:10}]; break;
      case 'get_purchase_activity': data=history.get(params.p_purchase_id)||[]; break;
      case 'create_purchase': {
        calls.push(path);
        const d=params.p_payload;
        const p={...d,purchase_id:crypto.randomUUID(),brand_id:brand,company_name:'Beximco LPG',plant_name:'Meghna Filling Plant',truck_name:d.truck_id?'Dhaka Delivery Truck':null,status:'created',payment_status:'unpaid',created_at:now,dispatched_at:null,received_at:null,paid_at:null,receipt_notes:null,legacy_record:false,revision:1,items:[]};
        purchases.unshift(p); record(p,'created');recalculate(p);data={purchase_id:p.purchase_id};break;
      }
      case 'update_purchase': {
        calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);const d=params.p_payload;
        const saved=p.items;
        Object.assign(p,d);p.truck_name=p.truck_id?'Dhaka Delivery Truck':null;
        if(d.items)p.items=d.items.map(i=>{
          const old=saved.find(item=>item.purchase_item_id===i.purchase_item_id);
          const billed=p.status==='created'?i.quantity:old?.billed_quantity??i.quantity;
          return {...i,purchase_item_id:i.purchase_item_id||crypto.randomUUID(),brand_name:'Beximco LPG',size_kg:12,mouth_size:'22mm',received_quantity:old?.received_quantity??null,billed_quantity:billed,line_total:billed*i.unit_price};
        });
        p.revision++;recalculate(p);record(p,'updated');data={};break;
      }
      case 'dispatch_purchase': {
        calls.push(path);
        if(failDispatch){failDispatch=false;await route.fulfill({status:400,json:{message:'Insufficient empty cylinder stock',code:'P0001'}});return;}
        const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);p.status='in_transit';p.dispatched_at=now;p.revision++;record(p,'dispatched',{empty_cylinders:p.items.reduce((s,i)=>s+i.empty_dispatched,0)});break;
      }
      case 'pay_purchase': { calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);p.payment_status='paid';p.paid_at=now;p.revision++;record(p,'paid',{total_cost:p.total_cost});break; }
      case 'receive_purchase': {
        calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);
        for(const line of params.p_items){const i=p.items.find(i=>i.purchase_item_id===line.purchase_item_id);i.received_quantity=line.received_quantity;if(p.payment_status==='unpaid'){i.billed_quantity=i.received_quantity;i.line_total=i.billed_quantity*i.unit_price;}}
        p.status='received';p.received_at=now;p.receipt_notes=params.p_receipt_notes;p.revision++;recalculate(p);record(p,'received',{notes:p.receipt_notes});break;
      }
      default: throw new Error('Unexpected fixture endpoint '+path);
    }
    await route.fulfill({json:data});
  });
  await page.setViewportSize({width:1440,height:1000});
  // A hash navigation alone does not execute the session init script.
  await page.reload();
  await page.goto('http://127.0.0.1:5173/#/purchases');
  const check=async(ok,label)=>{if(!ok)throw new Error('FAIL: '+label);};
  const openPurchase=async()=>{await page.getByRole('button').filter({hasText:'Meghna Filling Plant'}).first().click();};
  const selectPlant=async()=>{
    const input=page.getByRole('combobox',{name:'Destination plant'});
    await input.fill('Meghna');await input.press('Enter');
  };
  async function createPlantOnly() {
    const beforeCount=purchases.length;
    await page.getByRole('button',{name:'New Purchase',exact:true}).click();
    await selectPlant();
    await page.getByRole('dialog',{name:'New purchase',exact:true}).getByRole('button',{name:'Create purchase',exact:true}).click();
    await check(purchases.length===beforeCount,'creation waits for confirmation');
    await page.getByRole('dialog',{name:'Create this purchase?',exact:true}).getByRole('button',{name:'Create purchase',exact:true}).click();
    await page.getByRole('dialog',{name:'New purchase',exact:true}).waitFor({state:'hidden'});
  }
  await createPlantOnly();
  await check(purchases[0].items.length===0&&purchases[0].status==='created','plant-only creation');
  await openPurchase();
  let details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('combobox',{name:'Truck (optional until dispatch)'}).fill('Dhaka');
  await details.getByRole('combobox',{name:'Truck (optional until dispatch)'}).press('Enter');
  await details.getByRole('button',{name:'Add product',exact:true}).click();
  let line=details.locator('article').nth(0);
  await line.getByRole('combobox').fill('Beximco');
  await check(await page.getByRole('option').filter({hasText:'Other company'}).count()===0,'company product filtering');
  await line.getByRole('combobox').press('Enter');
  await line.getByLabel('Expected refills',{exact:true}).fill('4');
  await line.getByLabel('Empty cylinders to dispatch',{exact:true}).fill('6');
  await line.getByLabel('Unit price (Tk)',{exact:true}).fill('100');
  await details.getByRole('button',{name:'Add product',exact:true}).click();
  line=details.locator('article').nth(1);
  await line.getByRole('button',{name:'New',exact:true}).click();
  await line.getByRole('combobox').fill('Beximco');await line.getByRole('combobox').press('Enter');
  await line.getByLabel('Expected new cylinders',{exact:true}).fill('2');
  await line.getByLabel('Unit price (Tk)',{exact:true}).fill('200');
  await details.getByLabel('Commission (Tk)',{exact:true}).fill('50');
  await details.getByLabel('Transport cost (Tk)',{exact:true}).fill('20');
  await details.getByLabel('Labour cost (Tk)',{exact:true}).fill('10');
  await check(await details.getByRole('button',{name:'Dispatch truck',exact:true}).isDisabled(),'unsaved changes block transitions');
  await page.screenshot({path:'.temp/purchase-verification/edit-desktop.png'});
  await details.getByRole('button',{name:'Save changes',exact:true}).click();
  await details.waitFor({state:'hidden'});
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  failDispatch=true;
  await details.getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await page.getByRole('dialog',{name:'Dispatch this truck?',exact:true}).getByRole('button',{name:'Go back',exact:true}).click();
  await check(purchases[0].status==='created','cancelled dispatch has no mutation');
  await details.getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await page.getByRole('dialog',{name:'Dispatch this truck?',exact:true}).getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await details.getByRole('alert').waitFor();
  await check(purchases[0].status==='created','failed transition retains editable purchase');
  await details.getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await page.getByRole('dialog',{name:'Dispatch this truck?',exact:true}).getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await details.waitFor({state:'hidden'});
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await check(await details.getByLabel('Expected refills',{exact:true}).count()===0,'dispatched quantities become read-only');
  await details.getByRole('button',{name:'Record full payment',exact:true}).click();
  await page.getByRole('dialog',{name:'Record full payment?',exact:true}).getByRole('button',{name:'Record full payment',exact:true}).click();
  await details.waitFor({state:'hidden'});
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await check(await details.getByLabel('Commission (Tk)',{exact:true}).count()===0,'prepaid costs become read-only');
  await details.getByRole('button',{name:'Receive shipment',exact:true}).click();
  const receipt=page.getByRole('dialog',{name:'Receive shipment',exact:true});
  await receipt.getByLabel('Received refills',{exact:true}).fill('3');
  await receipt.getByLabel('Received new cylinders',{exact:true}).fill('4');
  await receipt.getByRole('button',{name:'Receive shipment',exact:true}).click();
  await receipt.getByRole('alert').waitFor();
  await receipt.getByLabel(/Receipt notes/).fill('One refill short; two extra new cylinders.');
  await receipt.getByRole('button',{name:'Receive shipment',exact:true}).click();
  await page.getByRole('dialog',{name:'Finalize this receipt?',exact:true}).getByRole('button',{name:'Receive shipment',exact:true}).click();
  await details.waitFor({state:'hidden'});
  await check(purchases[0].total_cost===780&&purchases[0].items[0].received_quantity===3,'prepaid receipt retains total');
  await openPurchase();
  const completed=page.getByRole('dialog',{name:'Completed purchase',exact:true});
  await check(await completed.locator('input,textarea,select').count()===0,'completed summary contains no disabled form controls');
  await check(await completed.getByRole('heading',{name:'Activity history',exact:true}).isVisible(),'completed summary has history');
  await page.screenshot({path:'.temp/purchase-verification/completed-desktop.png'});
  await page.setViewportSize({width:390,height:844});
  await check(await completed.evaluate(el=>el.getBoundingClientRect().right<=window.innerWidth),'mobile modal fits viewport');
  await page.screenshot({path:'.temp/purchase-verification/completed-mobile.png'});
  await completed.getByRole('button',{name:'Close',exact:true}).click();
  await page.getByRole('combobox',{name:'Payment status',exact:true}).fill('Unpaid');await page.getByRole('combobox',{name:'Payment status',exact:true}).press('Enter');
  await check(await page.getByText('No purchases match these filters.',{exact:true}).isVisible(),'payment filtering');
  await page.getByRole('combobox',{name:'Payment status',exact:true}).fill('All');await page.getByRole('combobox',{name:'Payment status',exact:true}).press('Enter');
  // Receive before payment and edit financials on the finalized delivery.
  await createPlantOnly();
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('combobox',{name:'Truck (optional until dispatch)'}).fill('Dhaka');
  await details.getByRole('combobox',{name:'Truck (optional until dispatch)'}).press('Enter');
  await details.getByRole('button',{name:'Add product',exact:true}).click();
  line=details.locator('article').first();
  await line.getByRole('button',{name:'New',exact:true}).click();
  await line.getByRole('combobox').fill('Beximco');await line.getByRole('combobox').press('Enter');
  await line.getByLabel('Expected new cylinders',{exact:true}).fill('2');
  await line.getByLabel('Unit price (Tk)',{exact:true}).fill('250');
  await page.screenshot({path:'.temp/purchase-verification/edit-mobile.png'});
  await check(await details.evaluate(el=>el.scrollWidth<=el.clientWidth),'mobile editing has no horizontal overflow');
  await details.getByRole('button',{name:'Save changes',exact:true}).click();await details.waitFor({state:'hidden'});
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await page.getByRole('dialog',{name:'Dispatch this truck?',exact:true}).getByRole('button',{name:'Dispatch truck',exact:true}).click();await details.waitFor({state:'hidden'});
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('button',{name:'Receive shipment',exact:true}).click();
  const unpaidReceipt=page.getByRole('dialog',{name:'Receive shipment',exact:true});
  await unpaidReceipt.getByRole('button',{name:'Use expected quantities',exact:true}).click();
  await unpaidReceipt.getByLabel('Received new cylinders',{exact:true}).fill('1');
  await unpaidReceipt.getByLabel(/Receipt notes/).fill('One new cylinder short.');
  await unpaidReceipt.getByRole('button',{name:'Receive shipment',exact:true}).click();
  await page.getByRole('dialog',{name:'Finalize this receipt?',exact:true}).getByRole('button',{name:'Receive shipment',exact:true}).click();await details.waitFor({state:'hidden'});
  await check(purchases[0].payment_status==='unpaid'&&purchases[0].subtotal===250,'unpaid receipt bills actual delivery');
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByLabel('Unit price (Tk)',{exact:true}).fill('260');
  await details.getByRole('button',{name:'Save changes',exact:true}).click();await details.waitFor({state:'hidden'});
  await check(purchases[0].subtotal===260&&purchases[0].items[0].received_quantity===1,'received unpaid prices editable without changing receipt');
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('button',{name:'Record full payment',exact:true}).click();
  await page.getByRole('dialog',{name:'Record full payment?',exact:true}).getByRole('button',{name:'Record full payment',exact:true}).click();await details.waitFor({state:'hidden'});
  // A view-only account must also have no actions on an unfinished shipment.
  const viewed={...purchases[0],purchase_id:crypto.randomUUID(),status:'in_transit',payment_status:'unpaid',received_at:null,paid_at:null};
  purchases.unshift(viewed);
  role='view';await page.reload();
  await page.getByRole('heading',{name:'Purchases',exact:true}).waitFor();
  await check(await page.getByRole('button',{name:'New Purchase',exact:true}).count()===0,'view-only user has no create action');
  await openPurchase();
  await check(await page.getByRole('button',{name:'Save changes',exact:true}).count()===0,'view-only summary has no mutation actions');
  await check(await page.getByRole('button',{name:'Receive shipment',exact:true}).count()===0,'view-only user cannot receive unfinished shipment');
  return 'PASS: plant-only creation, keyboard selections, staged editing, confirmations, failed dispatch recovery, payment before/after receipt, discrepancy billing, completed summary, desktop/mobile layout, filters and unfinished view-only permissions (API fixtures).';
}
