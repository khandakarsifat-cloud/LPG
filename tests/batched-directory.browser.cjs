// Isolated fixtures: display pages and network batches must be independent.
async page => {
  const origin=new URL(page.url()).origin,id=n=>`bf${n.toString(16).padStart(6,'0')}-0000-4000-8000-000000000001`;
  const user={id:id(2),aud:'authenticated',role:'authenticated',email:'batch@example.invalid',app_metadata:{},user_metadata:{},created_at:new Date().toISOString()};
  const token='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'+btoa(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','').replaceAll('+','-').replaceAll('/','_')+'.Zml4dHVyZQ';
  await page.context().addInitScript(({user,token})=>{
    localStorage.setItem('lpg-sidebar-collapsed','false');
    for(const host of ['api.lpg.144.79.249.4.sslip.io','127.0.0.1:54321','localhost:54321','127.0.0.1:55421'])localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify({access_token:token,refresh_token:'fixture',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user}));
  },{user,token});
  const customers=Array.from({length:76},(_,n)=>({customer_id:id(100+n),name:`Customer ${String(n+1).padStart(3,'0')}`,display_name:`Customer ${String(n+1).padStart(3,'0')}`,tier:'retail',shop_name:null,phone:`017${String(n+1).padStart(8,'0')}`,address:'Dhaka',created_at:'2026-01-01T00:00:00Z',last_transaction_at:'2026-10-19T00:00:00Z',transactions:1,refill:1,package:0,total_sold:1,total_sold_amount:1000,total_due:100}));
  const purchases=customers.map((c,n)=>({purchase_id:id(300+n),company_name:`Company ${String(n+1).padStart(3,'0')}${n%3?'':' with a very long company name that wraps over several lines'}`,plant_name:'Fixture plant',truck_name:'Fixture truck with a long vehicle name',status:'received',payment_status:'paid',created_at:'2026-10-19T00:00:00Z',subtotal:100,total_cost:100,paid_amount:100,company_payable:100,commission:0,transport_cost:0,labour_cost:0,revision:1,items:Array.from({length:n%2?7:1},(_,i)=>({purchase_item_id:id(500+n*10+i),brand_name:'Fixture brand',size_kg:12,mouth_size:'22mm',type:'refill',quantity:1,received_quantity:1,unit_price:100,line_total:100}))}));
  const sales=customers.map((c,n)=>({...c,name:c.name+(n%3?'':' with a very long customer name that wraps over several lines'),sale_id:id(700+n),sale_tier:'retail',created_at:'2026-10-19T00:00:00Z',total_amount:100,original_total:100,paid_amount:100,due:0,additional_charges:0,expected:n%2?12:0,received_bottles:0,outstanding_bottles:n%2?12:0,items:Array.from({length:n%3===0?0:n%3===1?1:12},(_,i)=>({item_id:id(1000+n*20+i),name:'Long product name 12kg 22mm with additional product identification',type:'package',quantity:1}))}));
  purchases[0].total_cost=9999999999.99;purchases[0].paid_amount=9999999999.99;
  sales[0].total_amount=9999999999.99;sales[0].paid_amount=9999999999.99;
  const calls=[];let failOffset=null;let visibleTotal=76;let heldOffset=null, releaseBatch, batchGate;
  await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));
  await page.route('**/rest/v1/**',async route=>{
    const req=route.request(),name=new URL(req.url()).pathname.split('/').pop(),args=req.method()==='POST'?req.postDataJSON():{};
    let data=[];
    if(name==='user_profiles')data=[{tenant_id:id(1),full_name:'Batch operator',email:user.email,tenants:{business_name:'Batch verification'}}];
    else if(name==='get_my_preferences')data={theme:null};
    else if(name==='get_business_catalogs')data={roles:['Owner','Manager','Salesman','Driver','Helper','General Staff'].map((name,i)=>({id:String(i),name,active:true,system:true,assigned:0})),weights:[5,12,25,35].map(size_kg=>({size_kg,active:true,assigned:0}))};
    else if(name==='get_my_permissions')data=['customers:view','customers:manage','purchases:view','purchases:manage','sales:view'];
    else if(name==='get_customer_overview')data={wholesale:0,retail:76,new_wholesale:0,new_retail:0,inactive_wholesale:0,inactive_retail:0,week_start:'2026-10-17',inactive_since:'2026-08-20'};
    else if(name==='get_purchase_overview')data={total:76,created:0,in_transit:0,unpaid:0,company_payable:0};
    else if(name==='get_sales_overview')data={total:76,amount:7600,due:0,bottles:0};
    else if(['get_customer_directory','get_purchase_directory','get_sales_directory'].includes(name)){
      calls.push({name,...args});
      if(args.p_offset===heldOffset)await batchGate;
      if(args.p_offset===failOffset)return route.fulfill({status:500,json:{message:'Fixture batch failed'}});
      const rows=name==='get_customer_directory'?customers:name==='get_sales_directory'?sales:purchases;
      data={total:visibleTotal,entries:rows.slice(0,visibleTotal).slice(args.p_offset,args.p_offset+args.p_limit)};
    }
    return route.fulfill({json:data});
  });
  const check=(value,message)=>{if(!value)throw Error(message);};
  const samples=[];
  await page.clock.install();
  for(const route of ['customers','purchases','sales']){
    await page.setViewportSize({width:1366,height:734});
    await page.goto(origin+'/?batch-fixture='+route+Date.now()+'#/'+route);
    const selector=route==='customers'?'.customer-grid':'.purchases-grid',rpc=route==='customers'?'get_customer_directory':route==='sales'?'get_sales_directory':'get_purchase_directory';
    const requests=()=>calls.filter(c=>c.name===rpc);
    const nav=page.getByRole('navigation',{name:route+' pages'});
    const waitPage=async(start,size,total=76)=>page.waitForFunction(({selector,start,size,route,total})=>{
      const grid=document.querySelector(selector),cards=[...(grid?.children||[])];
      const first=cards[0];
      return grid?.getAttribute('aria-busy')==='false'&&cards.length===Math.min(size,total-start)&&(route==='customers'?first?.querySelector('strong')?.textContent===`Customer ${String(start+1).padStart(3,'0')}`:first?.getAttribute(route==='sales'?'data-sale-id':'data-purchase-id')===`bf${((route==='sales'?700:300)+start).toString(16).padStart(6,'0')}-0000-4000-8000-000000000001`);
    },{selector,start,size,route,total}).catch(async error=>{
      console.log('Directory state',route,start,size,total,await nav.innerText(),await page.locator(selector).evaluate(g=>({busy:g.getAttribute('aria-busy'),count:g.children.length,first:g.firstElementChild?.textContent})),requests());
      throw error;
    });
    await waitPage(0,12);
    check(requests().length===1&&requests()[0].p_limit===25&&requests()[0].p_offset===0,'First page must fetch exactly one batch of 25');
    for(const [start,expectedRequests] of [[12,1],[24,2],[36,2],[48,3]]){
      if(start===24){heldOffset=25;batchGate=new Promise(resolve=>{releaseBatch=resolve;});}
      await nav.getByRole('button',{name:'Next page',exact:true}).click();
      if(start===24){
        await page.waitForFunction(selector=>document.querySelector(selector)?.getAttribute('aria-busy')==='true',selector);
        check(await page.locator(selector).locator(':scope > *').count()===12,'Uncached navigation cleared existing cards');
        check((await nav.innerText()).includes('13–24 of 76'),'Uncached navigation changed the range before cards arrived');
        check(await nav.getByRole('button',{name:'Page 2',exact:true}).getAttribute('aria-current')==='page','Loading page indicator no longer matches visible cards');
        releaseBatch();heldOffset=null;
      }
      await waitPage(start,12);
      check(requests().length===expectedRequests,`${route}: page starting at ${start} fetched an unnecessary batch`);
    }
    check(requests().map(r=>r.p_offset).join(',')==='0,25,50','Batch boundaries must stay at 25 regardless of display pages');
    // A nonzero anchor survives width and height changes, then returns exactly.
    await page.getByRole('button',{name:'Collapse sidebar',exact:true}).click();await waitPage(45,15);
    await page.setViewportSize({width:390,height:844});await waitPage(40,10);
    await page.setViewportSize({width:1366,height:734});await waitPage(45,15);
    await page.getByRole('button',{name:'Expand sidebar',exact:true}).click();await waitPage(48,12);
    check(requests().length===3,'Anchor resize must reuse loaded batches');
    await nav.getByRole('button',{name:'Page 1',exact:true}).click();await waitPage(0,12);
    await page.getByRole('button',{name:'Collapse sidebar',exact:true}).click();await waitPage(0,15);
    check(requests().length===3,'Sidebar collapse must reuse cached rows');
    await page.getByRole('button',{name:'Expand sidebar',exact:true}).click();await waitPage(0,12);
    for(const [width,height] of [[1366,1000],[1920,1080],[2048,1080],[1440,600],[390,844],[390,600],[320,568]]){
      await page.setViewportSize({width,height});
      const size=width<=600?10:await page.locator(selector).evaluate(grid=>getComputedStyle(grid).gridTemplateColumns.trim().split(/\s+/).length*3);
      await waitPage(0,size);
      const geometry=await page.locator(selector).evaluate(grid=>{const cards=[...grid.children].map(c=>c.getBoundingClientRect());return {width:cards[0].width,widths:cards.map(c=>c.width),heights:cards.map(c=>c.height),overlap:cards.some((a,i)=>cards.some((b,j)=>j>i&&a.x<b.right&&a.right>b.x&&a.y<b.bottom&&a.bottom>b.y)),rows:new Set(cards.map(c=>Math.round(c.top))).size};});
      check(width<=600||geometry.rows===3,'Desktop must show three rows regardless of window height or card height');
      check(geometry.widths.every(w=>Math.abs(w-geometry.width)<2),'Card widths changed within a page');
      if(route==='customers')check(geometry.heights.every(h=>Math.abs(h-geometry.heights[0])<1),'Customer card heights depend on their content');
      check(!geometry.overlap,'Directory cards overlap');
      if(route!=='customers')check(await page.locator(selector).evaluate(grid=>[...grid.children].every(card=>{
        const header=card.querySelector('.purchase-card-header').getBoundingClientRect(),statuses=card.querySelector('.record-statuses').getBoundingClientRect(),meta=card.querySelector('.purchase-card-meta').getBoundingClientRect();
        return statuses.top-header.bottom<=7 && meta.top-statuses.bottom<=7;
      })),'Transaction cards reserve empty identity/status rows');
      if(route!=='customers'){
        check(await page.locator('.card-product-preview[data-overflow]').count()>0,'Long product previews do not indicate hidden content');
        check(await page.locator('.card-product-preview:not([data-overflow])').count()>0,'Short product previews are unnecessarily faded');
        const financialFits=await page.locator('.record-card').evaluateAll(cards=>cards.every(card=>{
          const box=card.getBoundingClientRect(),financial=[card.querySelector('.sale-money'),card.querySelector('.purchase-card-footer'),...card.querySelectorAll('.sale-money strong,.purchase-total-value')];
          return financial.every(el=>{const r=el.getBoundingClientRect();return r.top>=box.top&&r.bottom<=box.bottom&&r.left>=box.left&&r.right<=box.right;});
        }));
        if(!financialFits){await page.screenshot({path:'.temp/ui-audit/financial-overflow.png'});console.log(await page.locator('.record-card').first().evaluate(card=>({card:card.getBoundingClientRect().toJSON(),money:[...card.querySelectorAll('.sale-money strong,.purchase-total-value')].map(el=>({class:el.className,rect:el.getBoundingClientRect().toJSON()}))})));}
        check(financialFits,`Essential money is outside the card at ${route} ${width}`);
      }
      check(requests().length===3,'Resizing must reuse cached batches');
      samples.push({route,width,height,count:size,rows:geometry.rows});
      if(width===320){
        for(const start of [10,20,30,40]){await nav.getByRole('button',{name:'Next page',exact:true}).click();await waitPage(start,10);}
        check(await page.locator('.page-content').evaluate(el=>el.scrollWidth<=el.clientWidth+1),'Middle-page controls overflow on a small phone');
        check(await nav.getByRole('button',{name:'Page 5',exact:true}).getAttribute('aria-current')==='page','Small-phone page 5 indicator drifted');
        await nav.getByRole('button',{name:'Page 1',exact:true}).click();await waitPage(0,10);
      }
      if(width===390||width===1366)await page.screenshot({path:'.temp/responsive/batched-'+route+'-'+width+'-'+height+'.png'});
    }
    await page.setViewportSize({width:1366,height:734});await waitPage(0,12);
    // A new filter gets its own batches, and a failed boundary can be retried.
    failOffset=25;
    await page.locator(route==='customers'?'#customer-search':route==='sales'?'#sales-search':'#purchase-search').fill('fixture');
    await page.waitForFunction(({rpc})=>document.querySelector(rpc==='get_customer_directory'?'.customer-grid':'.purchases-grid')?.getAttribute('aria-busy')==='false',{rpc});
    await nav.getByRole('button',{name:'Next page',exact:true}).click();await waitPage(12,12);
    await nav.getByRole('button',{name:'Next page',exact:true}).click();
    await page.getByRole('alert').filter({hasText:/could not be loaded/}).waitFor();
    failOffset=null;
    await page.getByRole('button',{name:'Retry',exact:true}).click();await waitPage(24,12);
    // Jumping to the end must not download all intervening batches.
    await page.locator(route==='customers'?'#customer-search':route==='sales'?'#sales-search':'#purchase-search').fill('jump');
    await waitPage(0,12);
    const beforeJump=requests().length;
    await nav.getByRole('button',{name:'Page 7',exact:true}).click();await waitPage(72,12);
    check(requests().slice(beforeJump).map(r=>r.p_offset).sort((a,b)=>a-b).join(',')==='50,75','A direct jump must fetch only the two intersecting batches');
    check(requests().every(r=>r.p_limit===25),'Every directory request must use a limit of 25');
    if(route==='sales'){
      // A polling count refresh must clamp a formerly valid last page.
      visibleTotal=37;
      try { await page.clock.runFor(30_050); } finally { await page.clock.resume(); }
      await waitPage(36,12,37);
      check((await nav.innerText()).includes('37'),'Shrinking total was not reflected');
      check(await nav.getByRole('button',{name:'Next page',exact:true}).isDisabled(),'Clamped last page permits invalid next');
      visibleTotal=76;
      try { await page.clock.runFor(30_050); } finally { await page.clock.resume(); }
      await waitPage(36,12,76);
      check(await nav.getByRole('button',{name:'Page 4',exact:true}).getAttribute('aria-current')==='page','Growing total resurrected a clamped navigation anchor');
      await page.locator('#sales-search').fill('temporary-filter');await waitPage(0,12,76);
      await page.locator('#sales-search').fill('jump');await waitPage(0,12,76);

    }

  }
  return JSON.stringify({result:'PASS',samples});
}
