// Design regression: one timeline, in-modal attendance and aligned timestamps.
async page => {
 const check = (ok, message) => { if (!ok) throw Error(message); };
 const origin = new URL(page.url()).origin;
 const id = n => `ea900000-0000-4000-8000-${String(n).padStart(12,'0')}`;
 const now = new Date().toISOString(), today = new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dhaka',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
 const month = today.slice(0,7)+'-01';
 const user = {id:id(2),aud:'authenticated',role:'authenticated',email:'profile-fixture@example.invalid',app_metadata:{},user_metadata:{},created_at:now};
 const token = 'eyJhbGciOiJIUzI1NiJ9.'+Buffer.from(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+86400,role:'authenticated',aud:'authenticated'})).toString('base64url')+'.Zml4dHVyZQ';
 await page.context().addInitScript(({user,token})=>{for(const host of ['api.lpg.144.79.249.4.sslip.io','127.0.0.1:54321','localhost:54321'])localStorage.setItem(`sb-${host}-auth-token`,JSON.stringify({access_token:token,refresh_token:'fixture',expires_at:Math.floor(Date.now()/1000)+86400,token_type:'bearer',user}));},{user,token});
 const employee={employee_id:id(3),name:'Demo Ayesha Akter',employee_type_name:'Accountant',business_unit:'gas_business',address:'Dhaka, Bangladesh',notes:'',current_salary:18500,is_active:true,revision:1,effective_from:month,joining_date:'2026-01-01',primary_phone:'01900300004',phones:[{phone:'01900300004',is_primary:true}]};
 const terminal={device_id:id(4),serial:'PROFILE-FIXTURE',name:'Shop MB20-VL',enabled:true,approved:true,last_seen_at:now,last_upload_at:now,last_event_at:now,last_batch_count:1,unmapped:0};
 const clockIn=today+'T08:30:00+06:00';
 const history=[
  {id:id(10),kind:'payment',description:'Salary · October 2026 · Part payment',amount:500,date:today,created_at:today+'T09:40:00+06:00',actor:'Owner',details:{kind:'salary',period:month},wallets:[{entry_id:id(30),wallet_name:'Cash Register',method:'cash',amount:500,reference:'',transaction_id:id(31)}],reversible:true},
  {id:id(11),kind:'attendance',description:'Clock out',amount:null,date:today,created_at:today+'T09:20:01+06:00',occurred_at:today+'T09:20:00+06:00',actor:null,details:{device_name:'Shop MB20-VL',pin:'1',timezone:'Asia/Dhaka',received_at:today+'T09:20:01+06:00',finalized:false},wallets:[],reversible:false},
  {id:id(12),kind:'attendance',description:'Clock in',amount:null,date:today,created_at:clockIn,occurred_at:clockIn,actor:null,details:{device_name:'Shop MB20-VL',pin:'1',timezone:'Asia/Dhaka',received_at:clockIn,finalized:false},wallets:[],reversible:false},
  {id:id(13),kind:'terms',description:'Salary & employment updated',amount:18500,date:month,created_at:month+'T10:00:00+06:00',actor:'Owner',details:{effective_from:month,reason:'Monthly salary revision',is_active:true},wallets:[],reversible:false},
  {id:id(14),kind:'profile',description:'Profile updated',amount:null,date:month,created_at:month+'T09:00:00+06:00',actor:'Owner',details:{},wallets:[],reversible:false}
 ].map(row=>({...row,employee_id:employee.employee_id,employee_name:employee.name}));
 const unknown=[],errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));
 await page.route('**/rest/v1/**',async route=>{
  const request=route.request(),name=new URL(request.url()).pathname.split('/').pop(),args=request.method()==='POST'?request.postDataJSON():{};let data;
  if(name==='user_profiles')data=[{tenant_id:id(1),full_name:'Owner',email:user.email,tenants:{business_name:'Profile design fixture'}}];
  else if(name==='get_my_preferences')data={theme:null};
  else if(name==='get_business_catalogs')data={roles:['Owner','Manager','Salesman','Driver','Helper','General Staff'].map((name,i)=>({id:String(i),name,active:true,system:true,assigned:0})),weights:[5,12,25,35].map(size_kg=>({size_kg,active:true,assigned:0}))};
  else if(name==='get_my_permissions')data=['employees:view','employees:manage','payroll:view','payroll:pay','settings:manage'];
  else if(name==='get_employee_directory')data={entries:[employee],total:1};
  else if(name==='get_employee_overview')data={employees:1,active:1,types:['Accountant']};
  else if(name==='get_employee_profile')data={employee,terms:[{term_id:id(5),effective_from:month,monthly_salary:18500,is_active:true,reason:'Salary revision'}]};
  else if(name==='get_employee_salary_month')data={period:args.p_period,salary_amount:18500,paid:10000,outstanding:8500,established:true};
  else if(name==='get_attendance_configuration')data={today,timezone:'Asia/Dhaka',cutoff:'00:00:00',next_cutoff:'00:00:00',can_correct:true,devices:[terminal]};
  else if(name==='get_employee_attendance')data={entries:[{employee_id:employee.employee_id,name:employee.name,work_date:today,clock_in:clockIn,worked_seconds:0,automatic_close:false,manual:false,revision:1,clock_out:null,last_scan:today+'T09:20:00+06:00',scan_count:2,warning_count:0,cutoff:'15:00:00',timezone:'Asia/Dhaka',finalized:false,updated_at:now}],links:[{link_id:id(99),linked_at:now,unlinked_at:null,device_id:terminal.device_id,device_name:terminal.name,pin:'1'}]};
  else if(name==='get_employee_activity'){const f=args.p_filters??{},rows=history.filter(event=>(!f.kind||f.kind===event.kind)&&(!f.search||JSON.stringify(event).toLowerCase().includes(f.search.toLowerCase())));data={entries:rows.slice(args.p_offset,args.p_offset+args.p_limit),total:rows.length};}
  else if(name==='wallets'||name==='get_payment_wallets')data=[];
  else{unknown.push(name);data=[];}
  await route.fulfill({json:data});
 });
 await page.goto(origin+'/?profile-design-fixture=1#/employees');await page.getByRole('button',{name:'Open Demo Ayesha Akter',exact:true}).click();
 const profile=page.getByRole('dialog',{name:'Employee profile',exact:true});
 await profile.getByText('Estimated present',{exact:true}).waitFor();await profile.getByText('Salary · October 2026 · Part payment',{exact:true}).waitFor();
 check(await page.getByRole('region',{name:'Estimated shop presence'}).count()===0,'Attendance overview must not remain above the directory');
 check(await profile.getByRole('region',{name:'Employee activity history'}).count()===1,'Exactly one activity timeline');
 for(const title of ['Employment & salary revisions','Attendance history & device enrollment','Monthly salary history'])check(await profile.getByText(title,{exact:true}).count()===0,'Removed duplicate section: '+title);
 for(const kind of ['payment','attendance','terms','profile'])check(await profile.locator('.activity-'+kind).count()>0,'Timeline missing '+kind);
 for(const theme of ['light','dark'])for(const [width,height] of [[1440,1080],[768,1024],[375,812],[320,740]]){
  await page.setViewportSize({width,height});await page.emulateMedia({reducedMotion:'reduce',colorScheme:theme});await page.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);
  check(await profile.evaluate(el=>el.scrollWidth<=el.clientWidth+1),'Modal overflow at '+width);
  check(await profile.locator('.employee-profile-identity').evaluate(el=>el.scrollHeight<=el.clientHeight+1),'Identity block must not clip contacts or actions at '+width);
  check(await profile.locator('.employee-activity-row').evaluateAll(rows=>rows.every(row=>{const badge=row.querySelector('.employee-status-badge').getBoundingClientRect(),time=row.querySelector('time').getBoundingClientRect();return Math.abs(time.top-badge.top)<5&&time.left>badge.right;})),'Timestamp must stay on the heading row at '+width);
  check(await profile.locator('.employee-panel-note,.employee-profile-facts,.employee-salary-totals dt').evaluateAll(nodes=>nodes.every(node=>!['rgb(82, 96, 119)','rgb(96, 109, 128)','rgb(179, 190, 206)'].includes(getComputedStyle(node).color))),'Muted gray profile text remains');
  await profile.locator('.employee-profile-body').evaluate(el=>el.scrollTop=0);
  await page.screenshot({path:`.temp/employee-profile-redesign/profile-${width}-${theme}.png`,animations:'disabled'});
 }
 await page.setViewportSize({width:1440,height:1080});await profile.getByRole('button',{name:'Filters',exact:true}).click();await profile.getByRole('combobox',{name:'Activity type',exact:true}).selectOption('attendance');
 await profile.locator('.activity-payment').waitFor({state:'hidden'});await profile.locator('.activity-attendance').first().waitFor();check(await profile.locator('.activity-attendance').count()===2,'Attendance filter shares the same timeline');
 await profile.getByRole('combobox',{name:'Activity type',exact:true}).selectOption('terms');await profile.locator('.activity-terms').waitFor();check(await profile.locator('.employee-activity-row').count()===1,'Employment filter shares the same timeline');
 await profile.getByRole('combobox',{name:'Activity type',exact:true}).selectOption('');await profile.locator('.activity-payment').waitFor();
 await profile.locator('.activity-payment').getByRole('button',{name:'Return / correct payment',exact:true}).click();await profile.getByRole('heading',{name:'Return / correct payment',exact:true}).waitFor();
 check(errors.length===0,errors.join('\n'));check(unknown.length===0,'Unknown RPCs: '+unknown.join(','));
 return {passed:true,themes:['light','dark'],widths:[320,375,768,1440],timelineKinds:['payment','attendance','terms','profile']};
}
