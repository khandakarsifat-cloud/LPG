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
      case 'wallets': data=[{type:'dealership',balance:-1703906}]; break;
      case 'list_purchases': data=purchases; break;
      case 'list_gas_plants': data=[{plant_id:plant,plant_name:'Meghna Filling Plant',brand_id:brand,brand_name:'Beximco LPG',location:'Narayanganj',is_active:true}]; break;
      case 'list_trucks': data=[{truck_id:truck,name:'Dhaka Delivery Truck',serial_no:'Dhaka Metro 11-4520',status:purchases.some(p=>p.status==='in_transit')?'going':'idle',capacity:100}]; break;
      case 'items': data=[{item_id:sku,brand_id:brand,brand:'Beximco LPG',size_kg:12,mouth_size:'22mm',empty_quantity:20,lpg_brands:{brand_id:brand,brand_name:'Beximco LPG'}},
        {item_id:'other-sku',brand_id:'other-company',brand:'Other company',size_kg:12,mouth_size:'22mm',empty_quantity:10}]; break;
      case 'get_purchase_activity': data=history.get(params.p_purchase_id)||[]; break;
      case 'create_purchase': {
        calls.push(path);
        const d=params.p_payload;
        const p={...d,purchase_id:crypto.randomUUID(),brand_id:brand,company_name:'Beximco LPG',plant_name:'Meghna Filling Plant',truck_name:d.truck_id?'Dhaka Delivery Truck':null,status:'created',payment_status:'unpaid',created_at:new Date(Date.parse(now)+purchases.length*1000).toISOString(),dispatched_at:null,received_at:null,paid_at:null,receipt_notes:null,legacy_record:false,revision:1,items:[]};
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
  await page.goto(`${appUrl}/#/purchases`);
  const check=async(ok,label)=>{if(!ok)throw new Error('FAIL: '+label);};
  const openPurchase=async()=>{await page.getByRole('button').filter({hasText:'Meghna Filling Plant'}).first().click();};
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
  // Review the same product row in the New Purchase modal on desktop and mobile.
  await page.getByRole('button',{name:'New Purchase',exact:true}).click();
  await selectPlant();
  const newDialog=page.getByRole('dialog',{name:'New purchase',exact:true});
  await newDialog.getByRole('button',{name:'Add product',exact:true}).click();
  await newDialog.getByRole('combobox',{name:'Product 1',exact:true}).selectOption(sku);
  await newDialog.getByLabel('Expected refills',{exact:true}).fill('4');
  await newDialog.getByLabel('Unit price (Tk)',{exact:true}).fill('100');
  const productBox=await newDialog.getByRole('combobox',{name:'Product 1',exact:true}).boundingBox();
  const quantityBox=await newDialog.getByLabel('Expected refills',{exact:true}).boundingBox();
  await check(Math.abs(productBox.y-quantityBox.y)<2,'desktop product fields share one row');
  await newDialog.getByRole('combobox',{name:'Product 1',exact:true}).focus();
  await newDialog.getByRole('combobox',{name:'Product 1',exact:true}).press('b');
  await check(await newDialog.locator('input[role=combobox]').count()===0,'typing performs native selection, not free text');
  await page.screenshot({path:'.temp/purchase-verification/new-desktop.png'});
  await page.setViewportSize({width:390,height:844});
  await check(await newDialog.evaluate(el=>el.scrollWidth<=el.clientWidth),'mobile new purchase fits');
  await page.screenshot({path:'.temp/purchase-verification/new-mobile.png'});
  await newDialog.getByRole('button',{name:'Cancel',exact:true}).click();
  await page.setViewportSize({width:1440,height:1000});
  await createPlantOnly();
  await check(purchases[0].items.length===0&&purchases[0].status==='created','plant-only creation');
  await openPurchase();
  let details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('combobox',{name:'Truck (optional until dispatch)'}).selectOption(truck);
  await details.getByRole('button',{name:'Add product',exact:true}).click();
  let line=details.locator('article').nth(0);
  await line.getByRole('combobox').selectOption(sku);
  await check(await page.getByRole('option').filter({hasText:'Other company'}).count()===0,'company product filtering');
  await line.getByLabel('Expected refills',{exact:true}).fill('4');
  await check(await line.getByLabel('Empty cylinders to dispatch',{exact:true}).count()===0,'refill uses a single exchange quantity');
  await line.getByLabel('Unit price (Tk)',{exact:true}).fill('100');
  await details.getByRole('button',{name:'Add product',exact:true}).click();
  line=details.locator('article').nth(1);
  await line.getByRole('button',{name:'New',exact:true}).click();
  await line.getByRole('combobox').selectOption(sku);
  await line.getByLabel('Expected new cylinders',{exact:true}).fill('2');
  await line.getByLabel('Unit price (Tk)',{exact:true}).fill('200');
  await details.getByLabel('Commission (Tk)',{exact:true}).fill('50');
  await details.getByLabel('Transport cost (Tk)',{exact:true}).fill('20');
  await details.getByLabel('Labour cost (Tk)',{exact:true}).fill('10');
  await check(await details.getByRole('button',{name:'Dispatch truck',exact:true}).isDisabled(),'unsaved changes block transitions');
  await check(await details.locator('input[role=combobox]').count()===0,'selection fields are not editable text');
  await check(await line.getByRole('button',{name:'Refill',exact:true}).isDisabled(),'duplicate refill type cannot be selected for the same product');
  await page.screenshot({path:'.temp/purchase-verification/edit-desktop.png'});
  await details.getByRole('button',{name:'Save changes',exact:true}).click();
  await details.waitFor({state:'hidden'});
  await check(purchases[0].items[0].empty_dispatched===4 && purchases[0].items[1].empty_dispatched===0,'refill quantity controls outgoing empties; new cylinders send none');
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
  await check(await receipt.getByLabel('Received refills',{exact:true}).inputValue()==='4' && await receipt.getByLabel('Received new cylinders',{exact:true}).inputValue()==='2','all receipt quantities default to expected');
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
  await page.getByRole('combobox',{name:'Payment status',exact:true}).selectOption('unpaid');
  await check(await page.getByText('No purchases match these filters.',{exact:true}).isVisible(),'payment filtering');
  await page.getByRole('combobox',{name:'Payment status',exact:true}).selectOption('all');
  // Receive before payment and edit financials on the finalized delivery.
  await createPlantOnly();
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('combobox',{name:'Truck (optional until dispatch)'}).selectOption(truck);
  await details.getByRole('button',{name:'Add product',exact:true}).click();
  line=details.locator('article').first();
  await line.getByRole('button',{name:'New',exact:true}).click();
  await line.getByRole('combobox').selectOption(sku);
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
  await check(await unpaidReceipt.getByLabel('Received new cylinders',{exact:true}).inputValue()==='2','receipt defaults to expected quantity');
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
  // Receive a delivery without touching its expected-default quantity controls.
  await createPlantOnly();
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('combobox',{name:'Truck (optional until dispatch)'}).selectOption(truck);
  await details.getByRole('button',{name:'Add product',exact:true}).click();
  line=details.locator('article').first();
  await line.getByRole('button',{name:'New',exact:true}).click();
  await line.getByRole('combobox').selectOption(sku);
  await line.getByLabel('Expected new cylinders',{exact:true}).fill('2');
  await line.getByLabel('Unit price (Tk)',{exact:true}).fill('250');
  await details.getByRole('button',{name:'Save changes',exact:true}).click();await details.waitFor({state:'hidden'});
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('button',{name:'Dispatch truck',exact:true}).click();
  await page.getByRole('dialog',{name:'Dispatch this truck?',exact:true}).getByRole('button',{name:'Dispatch truck',exact:true}).click();await details.waitFor({state:'hidden'});
  await openPurchase();details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('button',{name:'Receive shipment',exact:true}).click();
  const defaultReceipt=page.getByRole('dialog',{name:'Receive shipment',exact:true});
  await check(await defaultReceipt.getByLabel('Received new cylinders',{exact:true}).inputValue()==='2','untouched receipt is ready with expected quantities');
  await page.screenshot({path:'.temp/purchase-verification/receipt-mobile.png'});
  await defaultReceipt.getByRole('button',{name:'Receive shipment',exact:true}).click();
  await page.getByRole('dialog',{name:'Finalize this receipt?',exact:true}).getByRole('button',{name:'Receive shipment',exact:true}).click();await details.waitFor({state:'hidden'});
  await check(purchases[0].items[0].received_quantity===2 && purchases[0].subtotal===500 && purchases[0].receipt_notes==='','untouched defaults are submitted as actual quantities without discrepancy notes');
  // Exercise the list with enough orders to overflow a short desktop viewport.
  for(let i=0;i<10;i++) purchases.push({...purchases[0],purchase_id:crypto.randomUUID(),plant_name:`Delivery plant ${i+1}`,
    created_at:`2026-10-${String(i+1).padStart(2,'0')}T12:00:00Z`,payment_status:'paid',subtotal:1000+i*100,company_payable:1000+i*100,total_cost:1000+i*100,
    company_name:i%2===0?'Jamuna Gas':'Bashundhara LPG',truck_name:i%2===0?'Ashok Leyland':'JAC',
    items:purchases[0].items.map(item=>({...item,unit_price:(1000+i*100)/2,line_total:1000+i*100,brand_name:i%2===0?'Jamuna Gas':'Bashundhara LPG'}))});
  await page.reload();
  await page.getByRole('heading',{name:'Purchases',exact:true}).waitFor();
  await page.setViewportSize({width:1366,height:646});
  await check(await page.locator('.purchase-wallet').evaluate(el=>el.classList.contains('negative')),'negative wallet has deficit styling');
  await check(await page.locator('#purchase-search').evaluate(el=>parseFloat(getComputedStyle(el).paddingLeft)>=32),'search text clears its icon');
  await check(await page.locator('.purchases-grid').evaluate(el=>el.scrollHeight<=el.clientHeight),'purchase grid does not create a nested scrollbar');
  await page.getByRole('button').filter({hasText:'Delivery plant 10'}).scrollIntoViewIfNeeded();
  await check(await page.getByRole('button').filter({hasText:'Delivery plant 10'}).isVisible(),'last purchase remains reachable');
  await page.locator('.page-content').evaluate(el=>el.scrollTop=0);
  await page.screenshot({path:'.temp/purchase-verification/list-desktop.png'});
  await page.getByLabel('Search purchases',{exact:true}).fill('not-a-plant');
  await page.getByRole('button',{name:'Clear filters',exact:true}).first().click();
  await check(await page.locator('.purchase-card').count()===purchases.length,'clear filters restores all orders');
  const searchControl=page.getByLabel('Search purchases',{exact:true});
  await searchControl.fill('  JAMUNA   ashok 22mm 12KG  ');
  await check(await page.locator('.purchase-card').count()===5,'AND search matches company, vehicle and specifications');
  await page.getByRole('combobox',{name:'Purchase status',exact:true}).selectOption('received');
  await page.getByRole('combobox',{name:'Payment status',exact:true}).selectOption('paid');
  await page.getByLabel('From',{exact:true}).fill('2026-10-03');
  await page.getByLabel('To',{exact:true}).fill('2026-10-07');
  await check(await page.locator('.purchase-card').count()===3,'search combines with status, payment and inclusive dates');
  await searchControl.fill('jamuna ashok, bashundhara 12kg');
  await check(await page.locator('.purchase-card').count()===5,'OR groups stay within active filters');
  await page.getByRole('combobox',{name:'Sort by',exact:true}).selectOption('amount_desc');
  await check((await page.locator('.purchase-card').first().innerText()).includes('Delivery plant 7'),'highest total first');
  await page.getByRole('combobox',{name:'Sort by',exact:true}).selectOption('amount_asc');
  await check((await page.locator('.purchase-card').first().innerText()).includes('Delivery plant 3'),'lowest total first');
  await page.getByRole('combobox',{name:'Sort by',exact:true}).selectOption('date_desc');
  await check((await page.locator('.purchase-card').first().innerText()).includes('Delivery plant 7'),'newest date first');
  await page.getByRole('combobox',{name:'Sort by',exact:true}).selectOption('date_asc');
  await check((await page.locator('.purchase-card').first().innerText()).includes('Delivery plant 3'),'oldest date first');
  await page.getByRole('combobox',{name:'Payment status',exact:true}).selectOption('unpaid');
  await check(await page.getByText('No purchases match these filters.',{exact:true}).isVisible(),'OR search cannot bypass payment filter');
  await page.getByRole('button',{name:'Clear filters',exact:true}).first().click();
  await check(await page.locator('.purchase-card').count()===purchases.length,'reset clears search, statuses, dates and sort');
  const workspace=page.getByRole('textbox',{name:'Search workspace',exact:true});
  await workspace.fill('Purchases');await workspace.press('Enter');
  await check(await workspace.inputValue()===''&&!await page.locator('#workspace-search-results').count(),'workspace search navigates and closes');
  // The landscape tablet has room for all header controls with a collapsed sidebar.
  await page.setViewportSize({width:1180,height:760});
  await page.getByRole('button',{name:'Collapse sidebar',exact:true}).click();
  await page.evaluate(async()=>{await Promise.all(document.getAnimations().map(a=>a.finished.catch(()=>{})));});
  const headerLayout=await page.locator('.purchases-header').evaluate(el=>{
    const title=el.querySelector('h1').getBoundingClientRect();
    const wallet=el.querySelector('.purchase-wallet').getBoundingClientRect();
    const button=el.querySelector('.btn-primary').getBoundingClientRect();
    const summary=el.querySelector('.purchase-list-summary').getBoundingClientRect();
    const lastSummary=el.querySelector('.purchase-list-summary > div:last-child').getBoundingClientRect();
    return {height:el.getBoundingClientRect().height,sameRow:Math.abs((title.top+title.bottom)/2-(wallet.top+wallet.bottom)/2)<12 && Math.abs((title.top+title.bottom)/2-(button.top+button.bottom)/2)<12,fillsMiddle:summary.left>title.right && summary.right<wallet.left && wallet.left-summary.right<=20 && Math.abs(lastSummary.right-summary.right)<2};
  });
  await page.screenshot({path:'.temp/purchase-verification/header-tablet.png'});
  await check(headerLayout.sameRow && headerLayout.height<=60,'tablet title, wallet and New Purchase share one compact row');
  await check(headerLayout.fillsMiddle,'summaries fill only the middle space reserved between the title and right-side actions');
  // Exercise both sidebar states and text scaling without changing business data.
  for(const collapsed of [true,false]) {
    if(!collapsed) await page.getByRole('button',{name:'Expand sidebar',exact:true}).click();
    for(const width of [1024,1180,1250,1366,1600,2560]) {
      await page.setViewportSize({width,height:800});
      await page.evaluate(async()=>{await Promise.all(document.getAnimations().map(a=>a.finished.catch(()=>{})));});
      await check(await page.locator('.purchases-header').evaluate(el=>{
        const title=el.querySelector('h1').getBoundingClientRect();
        const wallet=el.querySelector('.purchase-wallet').getBoundingClientRect();
        const action=el.querySelector('.btn-primary').getBoundingClientRect();
        return Math.abs((title.top+title.bottom)/2-(wallet.top+wallet.bottom)/2)<12 && wallet.right<=action.left && action.right<=el.getBoundingClientRect().right+1;
      }),`wallet and action stay with the heading at ${width}px, sidebar collapsed=${collapsed}`);
    }
  }
  await page.setViewportSize({width:1180,height:760});
  await page.getByRole('button',{name:'Collapse sidebar',exact:true}).click();
  await page.evaluate(()=>document.documentElement.style.fontSize='20px');
  await page.evaluate(async()=>{await Promise.all(document.getAnimations().map(a=>a.finished.catch(()=>{})));});
  await check(await page.locator('.page-content').evaluate(el=>el.scrollWidth<=el.clientWidth),'tablet header has no overflow with 125 percent text');
  await check(await page.locator('.purchases-header').evaluate(el=>{
    const title=el.querySelector('h1').getBoundingClientRect();
    const wallet=el.querySelector('.purchase-wallet').getBoundingClientRect();
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
    if(width<=768) await check(await page.locator('.purchases-header').evaluate(el=>{
      const title=el.querySelector('h1').getBoundingClientRect();
      const wallet=el.querySelector('.purchase-wallet').getBoundingClientRect();
      const action=el.querySelector('.btn-primary').getBoundingClientRect();
      const summaries=[...el.querySelectorAll('.purchase-list-summary > div')].map(node=>node.getBoundingClientRect());
      const center=box=>(box.top+box.bottom)/2;
      return Math.abs(center(title)-center(wallet))<12 && Math.abs(center(title)-center(action))<12 && summaries.every(box=>Math.abs(box.top-summaries[0].top)<2) && summaries[0].top>=Math.max(title.bottom,wallet.bottom,action.bottom);
    }),`portrait ${width}px puts heading, wallet and action in one row with all four summaries in the next row`);
  }
  await page.setViewportSize({width:390,height:844});
  await page.screenshot({path:'.temp/purchase-verification/list-mobile.png'});
  await page.getByRole('button',{name:'Switch to dark theme'}).click();
  await page.evaluate(async()=>{await Promise.all(document.getAnimations().map(animation=>animation.finished.catch(()=>{})));});
  await page.screenshot({path:'.temp/purchase-verification/list-mobile-dark.png'});
  await page.setViewportSize({width:1366,height:646});
  await page.screenshot({path:'.temp/purchase-verification/list-desktop-dark.png'});
  await page.getByRole('button',{name:'Switch to light theme'}).click();
  // A view-only account must also have no actions on an unfinished shipment.
  const viewed={...purchases[0],purchase_id:crypto.randomUUID(),status:'in_transit',payment_status:'unpaid',received_at:null,paid_at:null};
  purchases.unshift(viewed);
  role='view';await page.reload();
  await page.getByRole('heading',{name:'Purchases',exact:true}).waitFor();
  await check(await page.getByRole('button',{name:'New Purchase',exact:true}).count()===0,'view-only user has no create action');
  await openPurchase();
  await check(await page.getByRole('button',{name:'Save changes',exact:true}).count()===0,'view-only summary has no mutation actions');
  await check(await page.getByRole('button',{name:'Receive shipment',exact:true}).count()===0,'view-only user cannot receive unfinished shipment');
  return 'PASS: portrait two-row header at 320/390/768px, compact tablet header, summaries fill the remaining space beside reserved wallet/actions, both sidebar states at six desktop/tablet widths, 125 percent text, AND/OR search with status/payment/inclusive dates, four sort orders, automatic receipt defaults, single-quantity refill exchange, compact desktop product row, plant-only creation, native selections, staged editing, confirmations, failed dispatch recovery, payment before/after receipt, discrepancy billing, completed summary, five responsive widths, light/dark screenshots, list scrolling, negative wallet styling, search spacing/navigation, filter reset and unfinished view-only permissions (API fixtures).';
}
