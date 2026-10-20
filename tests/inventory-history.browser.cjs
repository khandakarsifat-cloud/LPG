// Isolated Auth/REST fixtures; exercise real controls and server query parameters without business writes.
async page => {
  await page.unroute('**/rest/v1/**');
  await page.unroute('**/auth/v1/**');
  const origin=new URL(page.url()).origin;
  const tenant='ab200000-0000-4000-8000-000000000001';
  const id=n=>`ab200000-0000-4000-8000-${String(n).padStart(12,'0')}`;
  const saleId='11111111-0000-4000-8000-000000000001';
  const purchaseId='22222222-0000-4000-8000-000000000001';
  const user={id:id(2),aud:'authenticated',role:'authenticated',email:'history@example.invalid',app_metadata:{},user_metadata:{},created_at:new Date().toISOString()};
  const payload=btoa(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','').replaceAll('+','-').replaceAll('/','_');
  const token='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'+payload+'.Zml4dHVyZQ';
  await page.context().addInitScript(({user,token})=>{
    const session=JSON.stringify({access_token:token,refresh_token:'fixture-refresh',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user});
    for(const host of ['api','127','localhost'])localStorage.setItem(`sb-${host}-auth-token`,session);
  },{user,token});
  const brands=[{brand_id:id(10),brand_name:'Jamuna Gas',is_active:true},{brand_id:id(11),brand_name:'Omera',is_active:true}];
  const items=[{tenant_id:tenant,item_id:id(20),brand_id:id(10),brand:'Jamuna Gas',size_kg:5,mouth_size:'22mm',filled_quantity:50,empty_quantity:20,lpg_brands:brands[0]},
    {tenant_id:tenant,item_id:id(21),brand_id:id(10),brand:'Jamuna Gas',size_kg:12,mouth_size:'22mm',filled_quantity:80,empty_quantity:40,lpg_brands:brands[0]},
    {tenant_id:tenant,item_id:id(22),brand_id:id(11),brand:'Omera',size_kg:25,mouth_size:'20mm',filled_quantity:20,empty_quantity:5,lpg_brands:brands[1]}];
  const movements=Array.from({length:38},(_,n)=>({tenant_id:tenant,movement_id:id(100+n),item_id:items[n%3].item_id,movement_type:'sale',reference_type:'sale',reference_id:saleId,
    filled_quantity_change:-1,empty_quantity_change:0,created_at:new Date(Date.parse('2026-10-19T08:00:00Z')-n*60000).toISOString(),notes:'POS Sale #11111111',created_by:user.id,items:items[n%3],user_profiles:{email:user.email}}));
  movements[1]={...movements[1],filled_quantity_change:0,empty_quantity_change:1};
  for(const n of [2,3,4,34,35])movements[n]={...movements[n],movement_type:'purchase',reference_type:n===2?'purchase_dispatch':n===4?'purchase_cancellation':'purchase_receipt_new',reference_id:purchaseId,
    filled_quantity_change:n===2?0:n===4?-5:5,empty_quantity_change:n===2?-5:n===4?5:0};
  movements[35]={...movements[35],reference_type:null,reference_id:null,notes:`Received goods from Purchase ${purchaseId}`};
  movements[37]={...movements[37],movement_type:'adjust_gain',reference_type:null,reference_id:null,notes:'Initial count',filled_quantity_change:5};
  const purchase={purchase_id:purchaseId,truck_id:null,truck_name:null,plant_id:id(50),plant_name:'Jamuna Gas',brand_id:id(10),company_name:'Jamuna Gas',status:'received',payment_status:'paid',subtotal:1000,commission:0,company_payable:1000,transport_cost:0,labour_cost:0,total_cost:1000,
    notes:null,receipt_notes:null,created_at:'2026-10-18T10:00:00Z',dispatched_at:'2026-10-18T11:00:00Z',received_at:'2026-10-18T12:00:00Z',paid_at:'2026-10-18T12:00:00Z',revision:1,legacy_record:false,
    items:[{purchase_item_id:id(55),item_id:id(20),brand_name:'Jamuna Gas',size_kg:5,mouth_size:'22mm',type:'package',quantity:5,empty_dispatched:0,received_quantity:5,billed_quantity:5,unit_price:200,line_total:1000}]};
  const requests=[];const errors=[];let viewer=false,failHistory=false,failSale=false;
  page.on('pageerror',error=>errors.push(error.message));
  await page.route('**/auth/v1/**',route=>route.fulfill({json:user}));
  await page.route('**/rest/v1/**',async route=>{
    const url=new URL(route.request().url());const name=url.pathname.split('/').pop();let data=[];
    switch(name){
      case 'user_profiles':data=[{tenant_id:tenant,full_name:'History verification',email:user.email,tenants:{business_name:'History verification'}}];break;
      case 'get_my_permissions':data=['inventory:view',...(!viewer?['inventory:manage','sales:view','purchases:view','purchases:manage']:[])];break;
      case 'list_lpg_brands':data=brands;break;
      case 'items':data=items;break;
      case 'inventory_movements':{
        requests.push(url.searchParams);
        if(failHistory)return route.fulfill({status:500,json:{message:'Fixture history failure'}});
        let rows=movements;
        const or=url.searchParams.get('or')??'';
        if(or.includes('purchase_dispatch'))rows=rows.filter(m=>m.reference_type?.startsWith('purchase_')||['purchase','refill','purchase_adjustment'].includes(m.movement_type));
        else if(or.includes('sale'))rows=rows.filter(m=>m.reference_type==='sale'||m.movement_type==='sale');
        const selected=url.searchParams.get('item_id');
        if(selected)rows=rows.filter(m=>selected.includes(m.item_id));
        for(const bound of url.searchParams.getAll('created_at')){const time=Date.parse(bound.slice(4));rows=rows.filter(m=>bound.startsWith('gte.')?Date.parse(m.created_at)>=time:Date.parse(m.created_at)<Date.parse(bound.slice(3)));}
        const offset=Number(url.searchParams.get('offset')??0),limit=Number(url.searchParams.get('limit')??31);
        data=rows.slice(offset,offset+limit);break;
      }
      case 'list_purchases':throw Error('Unbounded purchase read');
      case 'get_purchases_by_ids':if(viewer)throw Error('Viewer requested purchases');data=route.request().postDataJSON().p_ids.includes(purchaseId)?[purchase]:[];break;
      case 'get_purchase_activity':data=[];break;
      case 'sales':{
        if(viewer)throw Error('Viewer requested sales');
        if(url.searchParams.get('select')?.includes('sale_items')){
          if(failSale)return route.fulfill({status:500,json:{message:'Fixture sale failure'}});
          data={sale_id:saleId,sale_tier:'retail',created_at:'2026-10-19T08:00:00Z',subtotal:1200,total_amount:1200,discount_amount:0,exchange_fee:0,customers:{name:'Rahim',phone:'01700000000',tier:'retail'},
            sale_items:[{quantity:1,unit_price:1200,line_total:1200,type:'refill',items:{brand:'Jamuna Gas',size_kg:5,lpg_brands:{brand_name:'Jamuna Gas'}}}]};
        }else data=[{sale_id:saleId,sale_tier:'retail',customers:{name:'Rahim'}}];break;
      }
    }
    await route.fulfill({json:data});
  });
  const check=(value,label)=>{if(!value)throw Error('FAIL: '+label);};
  await page.setViewportSize({width:1440,height:1000});
  await page.goto(origin+'/?inventory-history-fixtures=1#/inventory');
  await page.reload();
  await page.getByRole('button',{name:'Inventory History',exact:true}).click();
  await page.getByText('Sold to Rahim on POS sale',{exact:false}).first().waitFor();
  check(await page.locator('.inv-history-row').count()===10,'bounded first history page');
  check((await page.locator('.inv-history').innerText()).includes('Received empty from Rahim on POS sale'),'empty return context');
  check((await page.locator('.inv-history').innerText()).includes('Sent empty to Jamuna Gas (plant) on purchase'),'dispatch plant context');
  check((await page.locator('.inv-history').innerText()).includes('Received package from Jamuna Gas (plant) on purchase'),'receipt plant context');
  await page.getByRole('button',{name:'Next',exact:true}).click();
  await page.getByText('Page 2',{exact:true}).waitFor();
  check(await page.locator('.inv-history-row').count()===10,'next page queries older rows');
  await page.getByRole('combobox',{name:'Activity',exact:true}).selectOption('purchase');
  await page.waitForFunction(()=>document.querySelectorAll('.inv-history-row').length===5);
  check(!await page.getByText('Page 2',{exact:true}).count(),'source change resets page');
  check(requests.at(-1).get('or').includes('purchase_cancellation'),'purchase reversals included by server filter');
  check((await page.locator('.inv-history').innerText()).includes('Received filled from Jamuna Gas (plant)'),'legacy purchase resolves full reference');
  await page.locator('.inv-history-reference').first().click();
  const purchaseDialog=page.getByRole('dialog',{name:'Completed purchase',exact:true});
  await purchaseDialog.waitFor();
  check((await purchaseDialog.innerText()).includes('Jamuna Gas'),'correct existing purchase modal');
  await purchaseDialog.getByRole('button',{name:'Close dialog',exact:true}).click();
  await page.getByRole('combobox',{name:'Activity',exact:true}).selectOption('sale');
  await page.getByText('Sold to Rahim on POS sale',{exact:false}).first().waitFor();
  check(!(await page.locator('.inv-history').innerText()).includes('(plant)'),'source filter excludes purchases');
  await page.locator('.inv-history-reference').first().click();
  const saleDialog=page.getByRole('dialog',{name:'Transaction #11111111',exact:true});
  await saleDialog.waitFor();
  check((await saleDialog.innerText()).includes('Rahim'),'exact saved sale detail');
  await saleDialog.getByRole('button',{name:'Back to history',exact:true}).click();
  check(await page.locator('.inv-history-reference').first().evaluate(el=>el===document.activeElement),'detail close restores reference focus');
  await page.getByRole('button',{name:/Select products/}).click();
  const picker=page.getByRole('dialog',{name:'Select products',exact:true});
  check(await picker.getByRole('button',{pressed:true}).count()===3,'all products initially selected');
  check((await picker.locator('.inv-tile-size').first().innerText()).startsWith('5'),'picker uses ascending weights');
  await picker.getByRole('button',{name:'Clear selection',exact:true}).click();
  await picker.locator('.inv-tile').first().click();
  await picker.locator('.inv-tile').last().click();
  await picker.getByRole('button',{name:'Apply 2 products',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.inv-filter-count')?.textContent==='2');
  check(requests.at(-1).get('item_id').includes(items[0].item_id)&&requests.at(-1).get('item_id').includes(items[2].item_id),'all selected IDs sent to server');
  check(requests.at(-1).get('or').includes('sale'),'source and product filters combined');
  check(await page.locator('.inv-history-row').evaluateAll(rows=>rows.every(row=>!row.textContent.includes('12 kg'))),'unselected products excluded');
  await page.getByRole('button',{name:/Select products/}).click();
  await picker.getByRole('button',{name:'Clear selection',exact:true}).click();
  await picker.getByRole('button',{name:'Cancel',exact:true}).click();
  check(await page.locator('.inv-filter-count').innerText()==='2','picker cancel retains applied selection');
  await page.getByRole('button',{name:/Select products/}).click();
  await picker.getByRole('button',{name:'Clear selection',exact:true}).click();
  await picker.getByRole('button',{name:'Apply 0 products',exact:true}).click();
  await page.getByText('No inventory history matches these filters.',{exact:true}).waitFor();
  check(await page.locator('.inv-history-row').count()===0,'empty selection means no products');
  await page.getByRole('button',{name:/Select products/}).click();
  await picker.getByRole('button',{name:'Select all',exact:true}).click();
  await picker.getByRole('button',{name:'Apply all products',exact:true}).click();
  await page.waitForFunction(()=>document.querySelectorAll('.inv-history-row').length===10);
  await page.getByRole('button',{name:'Clear filters',exact:true}).first().click();
  await page.getByRole('button',{name:'Next',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.inv-history-pagination')?.textContent.includes('Page 2'));
  await page.getByRole('button',{name:'Filter inventory history dates',exact:true}).click();
  const dates=page.getByRole('dialog',{name:'Inventory history dates',exact:true});
  await dates.getByLabel('From',{exact:true}).fill('2026-10-18');
  await dates.getByLabel('To',{exact:true}).fill('2026-10-18');
  await dates.getByRole('button',{name:'Apply dates',exact:true}).click();
  await page.getByText('No inventory history matches these filters.',{exact:true}).waitFor();
  check(requests.at(-1).getAll('created_at').includes('gte.2026-10-17T18:00:00.000Z')&&requests.at(-1).getAll('created_at').includes('lt.2026-10-18T18:00:00.000Z'),'Dhaka calendar bounds must filter on the server before pagination');
  check(Number(requests.at(-1).get('offset')??0)===0,'Timeline change resets history page');
  await page.getByRole('button',{name:'Filter inventory history dates',exact:true}).click();
  await dates.getByLabel('From',{exact:true}).fill('2026-10-19');
  await dates.getByRole('button',{name:'Cancel',exact:true}).click();
  check(await page.getByText('No inventory history matches these filters.',{exact:true}).isVisible(),'Cancelling dates retains the applied timeline');
  await page.getByRole('button',{name:'Clear filters',exact:true}).first().click();
  await page.locator('.inv-history-row').first().waitFor();
  for(const width of [1440,768,390,320])for(const theme of ['light','dark']){
    await page.setViewportSize({width,height:900});await page.evaluate(t=>document.documentElement.dataset.theme=t,theme);
    check(await page.locator('.inv-history-toolbar').evaluate(el=>el.scrollWidth<=el.clientWidth+1&&new Set([...el.children].map(child=>Math.round(child.getBoundingClientRect().bottom))).size===1),`history filters fit ${width} ${theme}`);
    check(await page.locator('.inv-history-row').evaluateAll(rows=>rows.every(el=>el.scrollWidth<=el.clientWidth+1)),`rows fit ${width}`);
    await page.screenshot({path:`.temp/inventory-history/history-${width}-${theme}.png`,animations:'disabled'});
  }
  await page.getByRole('button',{name:/Select products/}).click();
  check(await picker.evaluate(el=>el.scrollWidth<=el.clientWidth+1),'picker fits 320px');
  await picker.getByRole('button',{name:'Clear selection',exact:true}).click();await picker.locator('.inv-tile').first().click();
  await page.screenshot({path:'.temp/inventory-history/product-picker-320.png',animations:'disabled'});
  await page.keyboard.press('Escape');
  check(await picker.count()===0,'Escape cancels picker');
  // Compare three palettes on identical content; retain slate for neutral activity controls.
  await page.setViewportSize({width:1440,height:900});await page.evaluate(()=>document.documentElement.dataset.theme='light');
  const toolbar=page.locator('.inv-history-toolbar');
  for(const [name,color]of [['slate',null],['blue','#eaf1ff'],['green','#e7f7ef']]){
    await toolbar.evaluate((el,color)=>{if(color)el.style.background=color;else el.style.removeProperty('background');},color);
    await toolbar.screenshot({path:`.temp/inventory-history/palette-${name}.png`,animations:'disabled'});
  }
  await toolbar.evaluate(el=>el.style.removeProperty('background'));
  failHistory=true;await page.getByRole('button',{name:'Refresh',exact:true}).click();
  await page.getByRole('alert').filter({hasText:'Inventory history could not be loaded'}).waitFor();
  failHistory=false;await page.getByRole('button',{name:'Retry history',exact:true}).click();
  await page.getByText('Sold to Rahim on POS sale',{exact:false}).first().waitFor();
  failSale=true;await page.reload();
  await page.getByRole('button',{name:'Inventory History',exact:true}).click();
  await page.getByText('Sold to Rahim on POS sale',{exact:false}).first().waitFor();
  await page.locator('.inv-history-reference').first().click();
  await page.getByRole('alert').filter({hasText:'This transaction could not be loaded.'}).waitFor();
  failSale=false;await page.getByRole('button',{name:'Retry',exact:true}).click();
  await saleDialog.waitFor();
  await saleDialog.getByRole('button',{name:'Back to history',exact:true}).click();
  viewer=true;await page.reload();
  await page.getByRole('button',{name:'Inventory History',exact:true}).click();
  await page.getByText('Sold to customer on POS sale',{exact:false}).first().waitFor();
  check(await page.locator('.inv-history-reference').count()===0,'inventory-only access never opens protected source details');
  check(errors.length===0,'no page errors: '+errors.join(', '));
  return 'PASS: commission-independent history, source/product server filters, pagination, full legacy references, sale/purchase modals, selection apply/cancel/all/none, error recovery, permissions and responsive palettes';
}
