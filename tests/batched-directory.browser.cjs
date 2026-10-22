// Isolated fixtures: display pages and network batches must be independent.
async page => {
  const origin=new URL(page.url()).origin,id=n=>`bf${n.toString(16).padStart(6,'0')}-0000-4000-8000-000000000001`;
  const user={id:id(2),aud:'authenticated',role:'authenticated',email:'batch@example.invalid',app_metadata:{},user_metadata:{},created_at:new Date().toISOString()};
  const token='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'+btoa(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','').replaceAll('+','-').replaceAll('/','_')+'.Zml4dHVyZQ';
  await page.context().addInitScript(({user,token})=>{
    for(const host of ['127','api','localhost'])localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify({access_token:token,refresh_token:'fixture',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user}));
  },{user,token});
  const customers=Array.from({length:76},(_,n)=>({customer_id:id(100+n),name:`Customer ${String(n+1).padStart(3,'0')}`,display_name:`Customer ${String(n+1).padStart(3,'0')}`,tier:'retail',shop_name:null,phone:`017${String(n+1).padStart(8,'0')}`,address:'Dhaka',created_at:'2026-01-01T00:00:00Z',last_transaction_at:'2026-10-19T00:00:00Z',transactions:1,refill:1,package:0,total_sold:1,total_sold_amount:1000,total_due:100}));
  const purchases=customers.map((c,n)=>({purchase_id:id(300+n),company_name:`Company ${String(n+1).padStart(3,'0')}`,plant_name:'Fixture plant',truck_name:'Fixture truck',status:'received',payment_status:'paid',created_at:'2026-10-19T00:00:00Z',subtotal:100,total_cost:100,company_payable:100,commission:0,transport_cost:0,labour_cost:0,revision:1,items:Array.from({length:n%2?7:1},(_,i)=>({purchase_item_id:id(500+n*10+i),brand_name:'Fixture brand',size_kg:12,mouth_size:'22mm',type:'refill',quantity:1,received_quantity:1,unit_price:100,line_total:100}))}));
  const calls=[];let failOffset=null;
  await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));
  await page.route('**/rest/v1/**',async route=>{
    const req=route.request(),name=new URL(req.url()).pathname.split('/').pop(),args=req.method()==='POST'?req.postDataJSON():{};
    let data=[];
    if(name==='user_profiles')data=[{tenant_id:id(1),full_name:'Batch operator',email:user.email,tenants:{business_name:'Batch verification'}}];
    else if(name==='get_my_permissions')data=['customers:view','customers:manage','purchases:view','purchases:manage'];
    else if(name==='get_customer_overview')data={wholesale:0,retail:76,new_wholesale:0,new_retail:0,inactive_wholesale:0,inactive_retail:0,week_start:'2026-10-17',inactive_since:'2026-08-20'};
    else if(name==='get_purchase_overview')data={total:76,created:0,in_transit:0,unpaid:0,company_payable:0};
    else if(['get_customer_directory','get_purchase_directory'].includes(name)){
      calls.push({name,...args});
      if(args.p_offset===failOffset)return route.fulfill({status:500,json:{message:'Fixture batch failed'}});
      const rows=name==='get_customer_directory'?customers:purchases;
      data={total:rows.length,entries:rows.slice(args.p_offset,args.p_offset+args.p_limit)};
    }
    return route.fulfill({json:data});
  });
  const check=(value,message)=>{if(!value)throw Error(message);};
  const samples=[];
  for(const route of ['customers','purchases']){
    await page.setViewportSize({width:1366,height:734});
    await page.goto(origin+'/?batch-fixture='+route+'#/'+route);
    const selector=route==='customers'?'.customer-grid':'.purchases-grid',rpc=route==='customers'?'get_customer_directory':'get_purchase_directory';
    const requests=()=>calls.filter(c=>c.name===rpc);
    const nav=page.getByRole('navigation',{name:route+' pages'});
    const waitPage=async(start,size)=>page.waitForFunction(({selector,start,size,route})=>{
      const grid=document.querySelector(selector),cards=[...(grid?.children||[])];
      const first=cards[0];
      return grid?.getAttribute('aria-busy')==='false'&&cards.length===Math.min(size,76-start)&&(route==='customers'?first?.querySelector('strong')?.textContent===`Customer ${String(start+1).padStart(3,'0')}`:first?.getAttribute('data-purchase-id')===`bf${(300+start).toString(16).padStart(6,'0')}-0000-4000-8000-000000000001`);
    },{selector,start,size,route});
    await waitPage(0,12);
    check(requests().length===1&&requests()[0].p_limit===25&&requests()[0].p_offset===0,'First page must fetch exactly one batch of 25');
    for(const [start,expectedRequests] of [[12,1],[24,2],[36,2],[48,3]]){
      await nav.getByRole('button',{name:'Next page',exact:true}).click();await waitPage(start,12);
      check(requests().length===expectedRequests,`${route}: page starting at ${start} fetched an unnecessary batch`);
    }
    check(requests().map(r=>r.p_offset).join(',')==='0,25,50','Batch boundaries must stay at 25 regardless of display pages');
    await nav.getByRole('button',{name:'Page 1',exact:true}).click();await waitPage(0,12);
    await page.getByRole('button',{name:'Collapse sidebar',exact:true}).click();await waitPage(0,15);
    check(requests().length===3,'Sidebar collapse must reuse cached rows');
    await page.getByRole('button',{name:'Expand sidebar',exact:true}).click();await waitPage(0,12);
    for(const [width,height] of [[1366,1000],[1920,1080],[2048,1080],[1440,600],[390,844],[390,600],[320,568]]){
      await page.setViewportSize({width,height});
      const size=width<=600?10:await page.locator(selector).evaluate(grid=>getComputedStyle(grid).gridTemplateColumns.trim().split(/\s+/).length*3);
      await waitPage(0,size);
      const geometry=await page.locator(selector).evaluate(grid=>{const cards=[...grid.children].map(c=>c.getBoundingClientRect());return {width:cards[0].width,widths:cards.map(c=>c.width),rows:new Set(cards.map(c=>Math.round(c.top))).size};});
      check(width<=600||geometry.rows===3,'Desktop must show three rows regardless of window height or card height');
      check(geometry.widths.every(w=>Math.abs(w-geometry.width)<2),'Card widths changed within a page');
      check(requests().length===3,'Resizing must reuse cached batches');
      samples.push({route,width,height,count:size,rows:geometry.rows});
      if(width===390||width===1366)await page.screenshot({path:'.temp/responsive/batched-'+route+'-'+width+'-'+height+'.png'});
    }
    await page.setViewportSize({width:1366,height:734});await waitPage(0,12);
    // A new filter gets its own batches, and a failed boundary can be retried.
    failOffset=25;
    await page.locator(route==='customers'?'#customer-search':'#purchase-search').fill('fixture');
    await page.waitForFunction(({rpc})=>document.querySelector(rpc==='get_customer_directory'?'.customer-grid':'.purchases-grid')?.getAttribute('aria-busy')==='false',{rpc});
    await nav.getByRole('button',{name:'Next page',exact:true}).click();await waitPage(12,12);
    await nav.getByRole('button',{name:'Next page',exact:true}).click();
    await page.getByRole('alert').filter({hasText:/could not be loaded/}).waitFor();
    failOffset=null;
    await page.getByRole('button',{name:'Retry',exact:true}).click();await waitPage(24,12);
    // Jumping to the end must not download all intervening batches.
    await page.locator(route==='customers'?'#customer-search':'#purchase-search').fill('jump');
    await waitPage(0,12);
    const beforeJump=requests().length;
    await nav.getByRole('button',{name:'Page 7',exact:true}).click();await waitPage(72,12);
    check(requests().slice(beforeJump).map(r=>r.p_offset).sort((a,b)=>a-b).join(',')==='50,75','A direct jump must fetch only the two intersecting batches');
    check(requests().every(r=>r.p_limit===25),'Every directory request must use a limit of 25');
  }
  return JSON.stringify({result:'PASS',samples});
}
