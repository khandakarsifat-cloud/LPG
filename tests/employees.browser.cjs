// Responsive UI and recovery fixtures; backend accounting is verified separately.
async page => {
 const check = (ok, message) => { if (!ok) throw new Error(message); };
 const origin = new URL(page.url()).origin;
 const id = n => `eb000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
 const now = new Date().toISOString(), month = now.slice(0,7)+'-01', today = now.slice(0,10);
 const user = { id:id(2), aud:'authenticated',role:'authenticated',email:'employee-fixture@example.invalid',app_metadata:{},user_metadata:{},created_at:now };
 const token = 'eyJhbGciOiJIUzI1NiJ9.'+Buffer.from(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,role:'authenticated',aud:'authenticated'})).toString('base64url')+'.Zml4dHVyZQ';
 await page.context().addInitScript(({user,token})=>{for(const host of ['api.lpg.144.79.249.4.sslip.io','127.0.0.1:54321','localhost:54321','127.0.0.1:55421'])localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify({access_token:token,refresh_token:'fixture',expires_at:Math.floor(Date.now()/1000)+86400,token_type:'bearer',user}));},{user,token});
 const wallets=[{wallet_id:id(10),name:'Cash Register',kind:'cash',type:'cash',balance:100000,is_active:true},{wallet_id:id(11),name:'Primary Bank Account',kind:'bank',type:'dealership',balance:100000,is_active:true}];
 const employees=Array.from({length:31},(_,i)=>({employee_id:id(100+i),name:`Employee ${String(i+1).padStart(2,'0')}`,address:'Mirpur, Dhaka',notes:'Fixture team member',business_unit:i%2?'truck_business':'gas_business',employee_type_name:i%2?'Driver':'Staff',current_salary:15000,is_active:i!==30,revision:1,effective_from:month,joining_date:month,phones:[{phone:`017${String(i).padStart(8,'0')}`,is_primary:true}],primary_phone:`017${String(i).padStart(8,'0')}`,paid:0}));
 const events=[]; const requests=new Map(),calls=[],errors=[],unknown=[]; let lose=true;
 page.on('pageerror',error=>errors.push(error.message));
 await page.route('**/auth/v1/**',route=>route.fulfill({json:user}));
 await page.route('**/rest/v1/**',async route=>{
  const request=route.request(),name=new URL(request.url()).pathname.split('/').pop(),args=request.method()==='POST'?request.postDataJSON():{};calls.push({name,args});let data;
  if(name==='user_profiles')data=[{tenant_id:id(1),full_name:'Employee Owner',email:user.email,tenants:{business_name:'Employee fixture business'}}];
  else if(name==='get_my_permissions')data=['employees:view','employees:manage','payroll:view','payroll:pay','finance:view','finance:manage','logistics:view','logistics:manage'];
  else if(name==='wallets'||name==='get_payment_wallets')data=wallets;
  else if(name==='get_employee_directory'){
   const f=args.p_filters??{};let rows=employees.filter(e=>(!f.search||JSON.stringify(e).toLowerCase().includes(f.search.toLowerCase()))&&(f.status==='all'||!f.status||e.is_active===(f.status==='active'))&&(f.unit==='all'||!f.unit||e.business_unit===f.unit)&&(!f.type||e.employee_type_name===f.type));
   rows=rows.sort((a,b)=>f.sort==='name_desc'?b.name.localeCompare(a.name):a.name.localeCompare(b.name));data={total:rows.length,entries:rows.slice(args.p_offset,args.p_offset+args.p_limit)};
  } else if(name==='get_employee_overview')data={employees:employees.length,active:employees.filter(e=>e.is_active).length,types:['Staff','Driver']};
  else if(name==='get_employee_profile'){const e=employees.find(e=>e.employee_id===args.p_employee_id);data={employee:e,terms:[{term_id:id(600),effective_from:month,monthly_salary:e.current_salary,is_active:e.is_active,reason:'Starting salary'}]};}
  else if(name==='get_employee_salary_month'){const e=employees.find(e=>e.employee_id===args.p_employee_id);data={period:args.p_period,salary_amount:e.current_salary,paid:e.paid,outstanding:(e.current_salary-e.paid),established:e.paid>0};}
  else if(name==='get_employee_salary_history'){const e=employees.find(e=>e.employee_id===args.p_employee_id);data={total:1,entries:[{period:month,salary_amount:e.current_salary,paid:e.paid,outstanding:(e.current_salary-e.paid),established:e.paid>0}]};}
  else if(name==='get_employee_activity'){let rows=events.filter(e=>(!args.p_filters.employee_id||args.p_filters.employee_id===e.employee_id)&&(!args.p_filters.search||JSON.stringify(e).toLowerCase().includes(args.p_filters.search.toLowerCase())));data={total:rows.length,entries:rows.slice(args.p_offset,args.p_offset+args.p_limit)};}
  else if(name==='employee_payment_operation'){
   const body=args.p_payload;
   if(requests.has(args.p_request_id))data=requests.get(args.p_request_id);
   else if(body.action==='pay'){
    const ids=[];for(const item of body.items){const e=employees.find(e=>e.employee_id===item.employee_id),amount=item.payments.reduce((s,p)=>s+p.amount,0),pid=id(1000+events.length);ids.push(pid);if(item.kind==='salary'){e.paid+=amount;}events.unshift({id:pid,employee_id:e.employee_id,employee_name:e.name,kind:'payment',description:(item.bonus_name||item.kind)+' · '+(item.description||''),date:item.payment_date,created_at:now,actor:'Owner',amount,details:{kind:item.kind,period:month},wallets:item.payments.map((p,i)=>({entry_id:id(2000+events.length+i),wallet_name:wallets.find(w=>w.wallet_id===p.wallet_id).name,method:'cash',amount:p.amount,reference:p.reference||'',transaction_id:id(3000+events.length+i)})),reversible:true});}data={payment_ids:ids};requests.set(args.p_request_id,data);if(lose){lose=false;await route.abort('failed');return;}
   }else data={payment_id:id(7001)};
  } else if(name==='save_employee'){data={employee_id:id(9000)};requests.set(args.p_request_id,data);}
  else{unknown.push(name);data=[];}
  await route.fulfill({json:data});
 });
 await page.setViewportSize({width:1440,height:950});await page.goto(origin+'/?employee-fixture=1#/employees');await page.getByRole('button',{name:'Open Employee 01',exact:true}).waitFor();
 check(await page.getByText('Monthly payroll',{exact:true}).count()===0,'No global payroll workspace');
 for(const [width,height] of [[320,640],[390,844],[768,1024],[1440,950]]){
  await page.setViewportSize({width,height});await page.waitForTimeout(250);await page.waitForFunction(()=>document.querySelector('.employee-grid')?.getAttribute('aria-busy')==='false');
  check(await page.locator('.page-content').evaluate(el=>el.scrollWidth<=el.clientWidth),'Directory overflow at '+width);
  const nav=page.getByRole('navigation',{name:'employees pages'});await nav.getByRole('button',{name:'Page 1',exact:true}).click();
  check(await page.locator('.employee-card').count()>0,'Cards rendered at '+width);
  const seen=[];
  for(let p=0;p<40;p++){
   await page.waitForFunction(()=>document.querySelector('.employee-grid')?.getAttribute('aria-busy')==='false');
   seen.push(...await page.locator('.employee-card').evaluateAll(rows=>rows.map(row=>row.getAttribute('data-employee-id'))));
   const next=nav.getByRole('button',{name:'Next page',exact:true});if(await next.isDisabled())break;await next.click();await page.waitForTimeout(80);
  }
  check(seen.length===31&&new Set(seen).size===31,'Pagination covers all employees once at '+width);
  await nav.getByRole('button',{name:'Page 1',exact:true}).click();

  await page.getByRole('button',{name:'Open Employee 01',exact:true}).click();
  const profile=page.getByRole('dialog',{name:'Employee profile',exact:true});await profile.getByRole('button',{name:'Give bonus',exact:true}).waitFor();
  check(await profile.evaluate(el=>el.scrollWidth<=el.clientWidth),'Profile overflow at '+width);
  await profile.getByRole('button',{name:'Close dialog',exact:true}).click();
 }
 await page.setViewportSize({width:390,height:844});await page.getByRole('button',{name:'Open Employee 01',exact:true}).click();
 let profile=page.getByRole('dialog',{name:'Employee profile',exact:true});await profile.getByRole('button',{name:'Pay salary',exact:true}).first().click();
 let payment=page.getByRole('dialog',{name:'Pay salary',exact:true});await payment.getByLabel('Salary month',{exact:true}).fill('2030-12');
 await payment.getByRole('textbox',{name:'Pay now (Tk)',exact:true}).fill('5000');check(await payment.getByRole('button',{name:/Split across wallets|Add payment/}).count()===0,'No split wallet controls');
 check(await page.locator('dialog[open]').count()===1,'Payment stays in same modal');check(await payment.evaluate(el=>el.scrollWidth<=el.clientWidth),'Single wallet payment fits phone');
 await payment.getByRole('button',{name:/^Pay Tk/}).click();await payment.getByRole('button',{name:'Recover request',exact:true}).waitFor();
 // Reload and recover original request without changing month or wallet.
 await page.reload();await page.getByRole('button',{name:'Recover request',exact:true}).click();await page.getByRole('button',{name:'Open Employee 01',exact:true}).click();
 profile=page.getByRole('dialog',{name:'Employee profile',exact:true});await profile.getByText('Activity history',{exact:true}).waitFor();
 check(events.length===1,'Response loss and recovery create one payment');
 const payCalls=calls.filter(c=>c.name==='employee_payment_operation'&&c.args.p_payload.action==='pay');check(payCalls.length===2,'Original and recovered request');
 check(JSON.stringify(payCalls[0].args)===JSON.stringify(payCalls[1].args),'Recovery retains exact key, month, amount and wallet');check(payCalls[0].args.p_payload.items[0].period==='2030-12-01','Future salary directly allocated');
 await profile.getByRole('button',{name:'Give bonus',exact:true}).click();const bonus=page.getByRole('dialog',{name:'Give bonus',exact:true});await bonus.getByRole('textbox',{name:'Bonus name',exact:true}).fill('Eid Bonus');await bonus.getByRole('textbox',{name:'Pay now (Tk)',exact:true}).fill('1000');await bonus.getByRole('textbox',{name:'Description (optional)',exact:true}).fill('Thank you');await bonus.getByRole('button',{name:/^Pay Tk/}).click();
 profile=page.getByRole('dialog',{name:'Employee profile',exact:true});await profile.getByText('Eid Bonus · Thank you',{exact:true}).waitFor();check(employees[0].paid===5000,'Bonus never pays salary');
 await profile.getByRole('button',{name:'Edit',exact:true}).click();const edit=page.getByRole('dialog',{name:'Edit employee',exact:true});await edit.getByRole('textbox',{name:'Employee name',exact:true}).waitFor();check(await page.locator('dialog[open]').count()===1,'Edit stays in profile modal');await edit.getByRole('button',{name:'Cancel',exact:true}).click();await page.getByRole('dialog',{name:'Employee profile',exact:true}).getByRole('button',{name:'Close dialog',exact:true}).click();
 await page.getByRole('textbox',{name:'Search employees',exact:true}).fill('Employee 31');await page.waitForTimeout(350);await page.getByRole('button',{name:'Open Employee 31',exact:true}).waitFor();check(await page.locator('.employee-card').count()===1,'Search filters directory');
 check(calls.filter(c=>c.name==='get_employee_directory').every(c=>c.args.p_limit===25),'Backend batches remain 25');check(errors.length===0,errors.join('\n'));check(unknown.length===0,'Unknown API calls: '+unknown.join(','));
 return {passed:true,payments:events.length,widths:[320,390,768,1440],recoveries:payCalls.length};
}
