// Intercepted browser acceptance; database integrity is exercised by SQL/API suites.
async page => {
 const base=new URL(page.url()).origin, id=n=>`fa000000-0000-4000-8000-${String(n).padStart(12,'0')}`, now=new Date().toISOString();
 const tenant=id(1), user={id:id(2),aud:'authenticated',role:'authenticated',email:'purchase-wallet-ui@example.invalid',app_metadata:{},user_metadata:{},created_at:now};
 const token='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'+btoa(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,role:'authenticated',aud:'authenticated'})).replaceAll('=','')+'.Zml4dHVyZQ';
 await page.context().addInitScript(({user,token})=>{const s=JSON.stringify({access_token:token,refresh_token:'fixture',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,token_type:'bearer',user});for(const h of ['127','api','localhost'])localStorage.setItem(`sb-${h}-auth-token`,s);},{user,token});
 const wallets=[['cash','Cash Register','cash'],['bkash','bKash','bkash'],['nagad','Nagad','nagad'],['dealership','Primary Bank Account','bank'],['custom','Test active wallet','bank']].map(([type,name,kind],i)=>({wallet_id:id(10+i),type,name,kind,is_active:true}));
 const make=(n,status)=>({purchase_id:id(n),truck_id:id(3),truck_name:'Test truck',plant_id:id(4),plant_name:'Test plant',brand_id:id(5),company_name:'Test company',status,payment_status:status==='received'?'paid':'unpaid',subtotal:1000,commission:100,company_payable:900,transport_cost:100,labour_cost:50,total_cost:1050,paid_amount:status==='received'?1050:100,refund_due:0,refunded_amount:0,financial_closed_at:null,transport_funded:100,notes:null,receipt_notes:null,created_at:now,received_at:status==='received'?now:null,revision:2,legacy_record:false,items:[{purchase_item_id:id(n+100),item_id:id(6),brand_name:'Test company',size_kg:12,mouth_size:'22mm',type:'refill',quantity:1,empty_dispatched:1,received_quantity:status==='received'?1:null,billed_quantity:1,unit_price:1000,line_total:1000}]});
 const purchases=[make(20,'in_transit'),make(21,'received')], obligations=[], payments=[], operations=new Map(), history=[];let owner=true,loseResponse=true;
 const check=(ok,label)=>{if(!ok)throw Error(label);};
 await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));
 await page.route('**/rest/v1/**',async route=>{
  const req=route.request(),name=new URL(req.url()).pathname.split('/').pop(),a=req.method()==='POST'?req.postDataJSON():{};let data=[];
  const p=purchases.find(p=>p.purchase_id===a.p_purchase_id);
  if(name==='user_profiles')data=[{tenant_id:tenant,email:user.email,full_name:'UI owner',tenants:{business_name:'Purchase fixture'}}];
  else if(name==='get_my_permissions')data=['purchases:view','purchases:manage','inventory:view','logistics:view','finance:view'];
  else if(name==='get_payment_wallets')data=wallets;
  else if(name==='wallets')data=wallets.map(w=>({...w,balance:0}));
  else if(name==='items')data=[{item_id:id(6),brand_id:id(5),brand:'Test company',size_kg:12,mouth_size:'22mm',empty_quantity:10,lpg_brands:{brand_name:'Test company'}}];
  else if(name==='get_purchase_directory')data={total:2,entries:purchases};
  else if(name==='get_purchase_overview')data={total:2,created:0,in_transit:1,unpaid:1,company_payable:950};
  else if(name==='get_purchases_by_ids')data=purchases.filter(p=>a.p_ids.includes(p.purchase_id));
  else if(name==='get_purchase_activity')data=history;
  else if(name==='get_purchase_settlement')data={total:p.total_cost,paid:p.paid_amount,due:p.status==='cancelled'?0:p.total_cost-p.paid_amount,refund_due:p.refund_due,refunded:p.refunded_amount,financial_closed_at:p.financial_closed_at,can_cancel:owner,legacy:false,financial_locked:p.payment_status!=='unpaid',obligations:obligations.filter(o=>o.purchase_id===p.purchase_id),payment_count:payments.length,payments:payments.slice(a.p_offset||0,(a.p_offset||0)+10)};
  else if(['record_purchase_payment','initiate_purchase_cancellation','refund_purchase'].includes(name)){
   if(operations.has(a.p_request_id))data=operations.get(a.p_request_id);
   else {
    if(name==='record_purchase_payment'){
     const total=a.p_payments.reduce((s,e)=>s+e.amount,0);p.paid_amount+=total;p.payment_status=p.paid_amount===p.total_cost?'paid':'partial';p.revision++;
     for(const e of a.p_payments){const w=wallets.find(w=>w.wallet_id===e.wallet_id);payments.push({transaction_id:crypto.randomUUID(),wallet_name:w.name,amount:-e.amount,type:'purchase_payment_company',created_at:now,operation_id:a.p_request_id,description:'Company payment',reference:e.reference,actor:'UI owner'});}
    } else if(name==='initiate_purchase_cancellation'){
     check(a.p_confirmation==='CANCEL','exact confirmation reached backend');check(p.status!=='received','received never cancelled');p.status='cancelled';p.refund_due=p.paid_amount;p.revision++;
     for(const [component,amount] of [['company',p.paid_amount-100],['transport',100]])if(amount>0)obligations.push({obligation_id:crypto.randomUUID(),purchase_id:p.purchase_id,component,amount,remaining:amount,refunded:0,logistics_amount:component==='transport'?100:0,credit_business:true,sources:[{transaction_id:id(99),wallet_name:'Original wallet label',amount:-amount,description:'Original payment'}]});
    } else {
     const o=obligations.find(o=>o.obligation_id===a.p_obligation_id),amount=a.p_payments.reduce((s,e)=>s+e.amount,0);o.remaining-=amount;o.refunded+=amount;p.refund_due-=amount;p.refunded_amount+=amount;p.financial_closed_at=p.refund_due===0?now:null;p.revision++;
    }
    data={purchase_id:p.purchase_id};operations.set(a.p_request_id,data);
    history.push({activity_id:crypto.randomUUID(),action:name==='record_purchase_payment'?'payment_recorded':name==='refund_purchase'?'refund_recorded':'cancellation_initiated',actor_name:'UI owner',created_at:now,details:{payments:a.p_payments,refund_due:p.refund_due}});
    if(name==='record_purchase_payment'&&loseResponse){loseResponse=false;await route.abort('failed');return;}
   }
  }
  await route.fulfill({json:data});
 });
 await page.goto(base+'/?purchase-wallet-ui=1#/purchases');await page.locator(`[data-purchase-id="${id(20)}"]`).click();
 const details=page.getByRole('dialog',{name:'Purchase details',exact:true});await details.getByRole('button',{name:'Record payment',exact:true}).click();
 let pay=page.getByRole('dialog',{name:'Pay purchase',exact:true});await pay.getByRole('button',{name:'Add payment',exact:true}).click();await pay.getByLabel('Payment 1 amount',{exact:true}).fill('200');
 await pay.getByRole('button',{name:'Add payment',exact:true}).click();await pay.getByLabel('Payment 2 wallet',{exact:true}).selectOption(wallets[1].wallet_id);await pay.getByLabel('Payment 2 amount',{exact:true}).fill('100');await pay.getByLabel('Payment 2 reference',{exact:true}).fill('UI-BK');
 for(const width of [390,768,1440]){await page.setViewportSize({width,height:900});check(await pay.evaluate(e=>e.scrollWidth<=e.clientWidth),'payment dialog fits '+width);await page.screenshot({path:'.temp/purchase-wallets/payment-'+width+'.png'});}
 await pay.getByRole('button',{name:'Record payment',exact:true}).click();await pay.getByRole('button',{name:'Recover transaction',exact:true}).waitFor();await pay.getByRole('button',{name:'Close',exact:true}).click();
 await details.getByRole('button',{name:'Recover transaction',exact:true}).click();await details.getByRole('button',{name:'Record payment',exact:true}).waitFor();check(purchases[0].paid_amount===400&&operations.size===1,'lost response recovered without duplicate payment');
 await details.getByLabel('Notes',{exact:true}).fill('Discard this unsaved note');
 await details.getByRole('button',{name:'Cancel purchase',exact:true}).click();const cancel=page.getByRole('dialog',{name:'Cancel this purchase?',exact:true});
 await cancel.getByLabel('Type exactly CANCEL').fill('cancel');check(await cancel.getByRole('button',{name:'Confirm cancellation',exact:true}).isDisabled(),'lowercase blocked');await cancel.getByLabel('Type exactly CANCEL').fill('CANCEL');
 await page.screenshot({path:'.temp/purchase-wallets/cancel.png'});await cancel.getByRole('button',{name:'Confirm cancellation',exact:true}).click();await details.getByRole('button',{name:'Record refund',exact:true}).click();
 check(await details.getByText('Save changes before dispatch, receipt or payment.',{exact:true}).count()===0,'cancellation discards unsaved draft state');
 let refund=page.getByRole('dialog',{name:'Record purchase refund',exact:true});await refund.getByRole('button',{name:'Add refund',exact:true}).click();await refund.getByLabel('Payment 1 amount',{exact:true}).fill('100');await refund.getByLabel('Payment 1 wallet',{exact:true}).selectOption(wallets[4].wallet_id);
 await refund.getByRole('button',{name:'Record refund',exact:true}).click();await details.getByRole('button',{name:'Record refund',exact:true}).waitFor();check(purchases[0].refund_due===300&&!purchases[0].financial_closed_at,'partial refund stays pending');
 while(purchases[0].refund_due>0){await details.getByRole('button',{name:'Record refund',exact:true}).click();refund=page.getByRole('dialog',{name:'Record purchase refund',exact:true});await refund.getByRole('button',{name:/Refund remaining/}).click();await refund.getByRole('button',{name:'Record refund',exact:true}).click();await refund.waitFor({state:'hidden'});}
 check(Boolean(purchases[0].financial_closed_at),'all obligations close purchase');await details.getByText(/Financially closed:/).waitFor();await details.getByRole('button',{name:'Close',exact:true}).click();
 await page.locator(`[data-purchase-id="${id(21)}"]`).click();check(await page.getByRole('button',{name:'Cancel purchase',exact:true}).count()===0,'received purchase has no cancellation');await page.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click();
 purchases[0].status='in_transit';purchases[0].revision++;owner=false;await page.reload();await page.locator(`[data-purchase-id="${id(20)}"]`).click();await page.getByText('Payments & refunds',{exact:true}).waitFor();check(await page.getByRole('button',{name:'Cancel purchase',exact:true}).count()===0,'non-owner cannot initiate cancellation');
 return 'PASS: desktop/tablet/mobile split-payment editor, response-loss recovery after dialog closure, exact confirmation, partial/custom-wallet refunds, pending/final closure, received and owner UI restrictions (intercepted APIs).';
}

