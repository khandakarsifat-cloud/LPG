// Intercepted audit rendering; real ledger completeness is covered by SQL/API tests.
async page => {
  const origin=new URL(page.url()).origin,id=n=>`ac000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
  const user={id:id(1),aud:'authenticated',role:'authenticated',email:'history@example.invalid',app_metadata:{},user_metadata:{}};
  const token='eyJhbGciOiJIUzI1NiJ9.'+btoa(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','')+'.Zml4dHVyZQ';
  await page.context().addInitScript(({user,token})=>{
    for(const host of ['api.lpg.144.79.249.4.sslip.io','127.0.0.1:54321','localhost:54321','127.0.0.1:55421'])localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify({access_token:token,refresh_token:'fixture',token_type:'bearer',expires_at:Math.floor(Date.now()/1000)+86400,user}));
  },{user,token});
  const purchase={purchase_id:id(2),business_category:'lpg',company_name:'Audit company',plant_name:'Audit depot',status:'cancelled',payment_status:'paid',created_at:'2026-10-20T06:00:00Z',subtotal:1000,total_cost:1000,company_payable:1000,paid_amount:1000,refund_due:200,refunded_amount:800,rebate_amount:0,transport_cost:0,labour_cost:0,revision:1,items:[]};
  const ledger=(n,amount)=>({transaction_id:id(30+n),purchase_payment_id:id(40+n),wallet_name:n===2?'Original Cash Register':'Refund bank',method:n===2?'cash':'bank',amount,type:amount<0?'purchase_payment_company':'purchase_refund',created_at:`2026-10-20T06:0${n}:00Z`,operation_id:id(50+n),description:amount<0?'Purchase company payment':'Partial company refund',reference:'AUDIT-REFERENCE-'+n,component:'company',actor:'Audit operator',obligation_id:amount>0?id(80):null});
  const events=Array.from({length:8},(_,n)=>({activity_id:id(10+n),created_at:`2026-10-20T06:0${n}:00Z`,kind:n===2?'payment':n===7?'refund':'activity',actor_name:'Audit operator',message:n===0?'Purchase created.':'Gas quantity changed from 100 to 120.',amount:n===2?1000:n===7?800:null,wallet_entries:n===2?[ledger(n,-1000)]:n===7?[ledger(n,800)]:[]}));
  const check=(ok,message)=>{if(!ok)throw Error(message);};
  await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));
  await page.route('**/rest/v1/**',async r=>{
    const u=new URL(r.request().url()),name=u.pathname.split('/').pop();let data=[];
    if(name==='user_profiles')data=[{tenant_id:id(90),full_name:'Audit operator',email:user.email,tenants:{business_name:'Audit fixtures'}}];
    else if(name==='get_access_context')data={is_superadmin:false,must_change_password:false,reset_pending:false,tenant_id:id(90),business_name:'Audit fixtures',full_name:'Audit operator',email:user.email,role:'MANAGER',access_status:'active',permissions:['purchases:view']};
    else if(name==='get_my_preferences')data={theme:null};
    else if(name==='get_business_catalogs')data={roles:['Owner','Manager','Salesman','Driver','Helper','General Staff'].map((name,i)=>({id:String(i),name,active:true,system:true,assigned:0})),weights:[5,12,25,35].map(size_kg=>({size_kg,active:true,assigned:0}))};
    else if(name==='get_my_permissions')data=['purchases:view'];
    else if(name==='get_purchase_directory')data={total:1,entries:[purchase]};
    else if(name==='get_purchase_overview')data={total:1,created:0,in_transit:0,unpaid:0,company_payable:0};
    else if(name==='get_purchases_by_ids')data=[purchase];
    else if(name==='get_purchase_settlement')data={total:1000,paid:1000,due:0,refund_due:200,refunded:800,financial_closed_at:null,can_cancel:false,financial_locked:true,obligations:[],payment_count:2,payments:[ledger(2,-1000),ledger(7,800)]};
    else if(name==='get_purchase_activity'){const {p_offset,p_limit}=r.request().postDataJSON();data=events.slice(p_offset,p_offset+p_limit);}
    await r.fulfill({json:data});
  });
  await page.goto(origin+'/?purchase-history-fixture=1#/purchases');await page.locator('.purchase-card').click();
  const dialog=page.getByRole('dialog'),history=dialog.getByRole('region',{name:'Activity history',exact:true});
  await history.locator('.purchase-activity > li').nth(5).waitFor();
  check(await dialog.getByText('Payments & refunds',{exact:true}).count()===0,'Separate payment history remains');
  check(await dialog.locator('[data-transaction-id]').count()===1,'First page duplicates ledger entries');
  check((await history.innerText()).includes('Original Cash Register'),'Original wallet snapshot is absent');
  check((await history.innerText()).includes('Gas quantity changed from 100 to 120.'),'Stored edit message is absent');
  await history.getByText('Audit references',{exact:true}).click();
  check((await history.innerText()).includes(id(32))&&(await history.innerText()).includes('AUDIT-REFERENCE-2'),'Ledger/reference evidence is absent');
  await history.getByRole('button',{name:'Next page',exact:true}).click();
  await history.locator(`[data-transaction-id="${id(37)}"]`).waitFor();
  check(await history.locator('.purchase-activity > li').count()===2,'Activity pagination repeats or omits entries');
  check(await history.getByRole('button',{name:'Next page',exact:true}).isDisabled(),'History extends beyond the last entry');
  check((await history.innerText()).includes('+Tk 800.00'),'Refund sign or amount is missing');
  for(const theme of ['light','dark'])for(const width of [320,390,768,1440]){
    await page.setViewportSize({width,height:800});await page.evaluate(t=>document.documentElement.dataset.theme=t,theme);
    check(await dialog.evaluate(d=>{const body=d.querySelector('.modal-body');return d.scrollWidth<=d.clientWidth&&body.scrollWidth<=body.clientWidth;}),`Audit overflow at ${theme} ${width}`);
  }
  return 'PASS: one chronological purchase history, six-entry pages, payment/refund signs, immutable wallet/reference evidence and 320–1440px light/dark dialogs';
}
