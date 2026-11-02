// Intercepted browser fixtures; real Auth/PostgREST acceptance is a separate suite.
async page => {
 const base=new URL(page.url()).origin;
 const tenant='aa010000-0000-4000-8000-000000000001',uid='aa010000-0000-4000-8000-000000000002';
 const user={id:uid,email:'admin-fixture@example.invalid',aud:'authenticated',role:'authenticated',app_metadata:{},user_metadata:{},created_at:new Date().toISOString()};
 const token='eyJhbGciOiJIUzI1NiJ9.'+btoa(JSON.stringify({sub:uid,exp:Math.floor(Date.now()/1000)+86400,role:'authenticated'})).replaceAll('=','')+'.Zml4dHVyZQ';
 const catalogue=[['dashboard:view','Dashboard','View dashboard',[]],['inventory:view','Inventory','View inventory',[]],['inventory:manage','Inventory','Manage inventory',['inventory:view']],['purchases:view','Purchases','View purchases',[]],['purchases:manage','Purchases','Manage purchases',['purchases:view']],['purchases:pay','Purchases','Record purchase payments',['purchases:manage']],['purchases:create','Purchases','Create purchases',['purchases:manage']],['preferences:manage','Account','Personal preferences',[]],['users:manage','Access','Manage login accounts',[],true],['finance:view','Finance','View finance',[]]].map(([id,module,label,dependencies,owner_only])=>({id,module,label,dependencies,owner_only:!!owner_only}));
 const all=catalogue.map(p=>p.id);let mode='admin',workspace=null,forced=false,lastSaved=null,provisioned=0,managerCustom=null;
 const context=()=>({is_superadmin:mode==='admin',must_change_password:forced,reset_pending:false,tenant_id:mode==='admin'?workspace:tenant,business_name:'Fixture business',full_name:mode==='admin'?'Platform administrator':'Fixture owner',email:user.email,role:mode==='admin'?'SUPERADMIN':mode==='owner'?'OWNER':'SALESMAN',access_status:'active',permissions:forced?[]:mode==='admin'&&!workspace?[]:mode==='staff'?['dashboard:view','preferences:manage']:all});
 await page.context().addInitScript(({user,token})=>{const session=JSON.stringify({user,access_token:token,refresh_token:'fixture',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,token_type:'bearer'});for(const host of ['api.lpg.144.79.249.4.sslip.io','127.0.0.1:54321','localhost:54321'])localStorage.setItem(`sb-${host}-auth-token`,session);},{user,token});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/auth/v1/**',r=>r.fulfill({json:user}));
 await page.route('**/accounts/v1/**',async r=>{provisioned++;await r.fulfill({json:{user_id:'new-user',tenant_id:tenant}});});
 await page.route('**/rest/v1/**',async route=>{const name=new URL(route.request().url()).pathname.split('/').pop();let data=[];
  if(name==='get_access_context')data=context();
  if(name==='get_my_preferences')data={theme:null};
  if(name==='get_platform_dashboard')data={businesses:2,active:1,suspended:1,users:4,database_bytes:12000000,uploaded_bytes:12000,files:2};
  if(name==='get_platform_businesses')data={total:2,entries:[{tenant_id:tenant,business_name:'Fixture business',status:'active',created_at:new Date().toISOString(),users:3},{tenant_id:'aa020000-0000-4000-8000-000000000001',business_name:'Suspended fixture',status:'suspended',created_at:new Date().toISOString(),users:1}]};
  if(name==='get_platform_storage')data={measured_at:new Date().toISOString(),database_bytes:12000000,uploaded_bytes:12000,businesses:[{tenant_id:tenant,business_name:'Fixture business',database_estimate_bytes:5000,uploaded_bytes:12000,files:2}]};
  if(name==='get_permission_catalog')data=catalogue;
  if(name==='get_business_users')data={total:2,role_defaults:{MANAGER:all.filter(id=>id!=='users:manage'),SALESMAN:['dashboard:view','preferences:manage']},entries:[{user_id:'owner-fixture',tenant_id:tenant,full_name:'Business owner',email:'owner@example.invalid',role:'OWNER',is_active:true,revision:1,permissions:all,custom_permissions:null,last_sign_in_at:new Date().toISOString(),must_change_password:false},{user_id:'manager-fixture',tenant_id:tenant,full_name:'Business manager',email:'manager@example.invalid',role:'MANAGER',is_active:true,revision:1,permissions:all.filter(id=>id!=='users:manage'),custom_permissions:managerCustom,last_sign_in_at:null,must_change_password:false}]};
  if(name==='get_access_audit')data={entries:[{audit_id:'audit',action:'user_updated',actor_email:user.email,target_email:'manager@example.invalid',business_name:'Fixture business',created_at:new Date().toISOString(),details:{active:true}}]};
  if(name==='manage_business_user'){lastSaved=route.request().postDataJSON();managerCustom=lastSaved.p_permissions;data=null;}
  if(name==='set_admin_workspace'){workspace=route.request().postDataJSON().p_tenant_id;data=null;}
  if(name==='get_inventory_valuation')data={known_value:0,lpg_value:0,stove_value:0,reconstructed_products:0};
  if(name==='get_business_catalogs')data={roles:[],weights:[]};
  await route.fulfill({json:data});
 });
 const check=(ok,note)=>{if(!ok)throw Error(note);};
 await page.setViewportSize({width:1440,height:1000});await page.goto(base+'/?account-access-fixture='+Date.now()+'#/admin');await page.getByRole('heading',{name:'Platform overview'}).waitFor();
 check(await page.getByText('Registered businesses',{exact:true}).isVisible(),'Admin dashboard metrics missing');
 const refreshed=page.waitForResponse(r=>r.url().endsWith('/rpc/get_access_context'));
 await page.evaluate(()=>{const c=new BroadcastChannel('lpg-access-context');c.postMessage('changed');c.close();});await refreshed;
 await page.getByRole('button',{name:'Manage users',exact:true}).first().waitFor();
 await page.screenshot({path:'.temp/access-admin-desktop.png',fullPage:true});
 await page.getByRole('button',{name:'Manage users',exact:true}).first().click();await page.getByRole('heading',{name:'Fixture business',exact:true}).waitFor();
 await page.locator('.access-user-card').filter({hasText:'Business manager'}).getByRole('button',{name:'Manage access'}).click();
 await page.getByRole('checkbox',{name:'Customize this user’s permissions'}).check();
 await page.locator('.permission-groups summary').filter({hasText:'Purchases'}).click();
 await page.getByRole('checkbox',{name:'Record purchase payments',exact:false}).uncheck();
 check(await page.getByRole('checkbox',{name:/^Manage purchases /}).isChecked(),'Removing one action removed unrelated management');
 check(await page.getByRole('checkbox',{name:'Manage login accounts',exact:false}).count()===0,'Owner-only capability is delegable');
 check(await page.locator('dialog select option[value="OWNER"]').count()===0,'Staff can be promoted to OWNER in the form');
 await page.screenshot({path:'.temp/access-permissions-desktop.png',fullPage:true});
 await page.getByRole('button',{name:'Save access',exact:true}).click();await page.locator('dialog').waitFor({state:'detached'});
 check(!lastSaved.p_permissions.includes('purchases:pay')&&lastSaved.p_permissions.includes('purchases:create'),'Permission save mismatches the form');
 await page.getByRole('button',{name:'Create account',exact:true}).click();await page.getByLabel('Full name',{exact:true}).fill('New staff');await page.getByLabel('Login email',{exact:true}).fill('newstaff@example.invalid');await page.getByLabel('Temporary password',{exact:true}).fill('FixturePassword12345');await page.locator('dialog').getByRole('button',{name:'Create account',exact:true}).click();await page.locator('dialog').waitFor({state:'detached'});check(provisioned===1,'Account creation did not reach the server service');
 await page.getByRole('button',{name:'All businesses',exact:true}).click();await page.getByRole('button',{name:'Storage',exact:true}).click();await page.getByRole('heading',{name:'Storage by business'}).waitFor();check(await page.getByRole('cell',{name:'11.7 KB'}).isVisible(),'Uploaded-file usage missing');
 await page.getByRole('button',{name:'Backups',exact:true}).click();await page.getByRole('heading',{name:'Backup management'}).waitFor();check(await page.getByText('Reserved for future backup configuration',{exact:false}).isVisible(),'Backup section missing');
 await page.getByRole('button',{name:'Businesses & users',exact:true}).click();await page.getByRole('button',{name:'Suspend',exact:true}).click();check(await page.locator('dialog').getByRole('button',{name:'Suspend business',exact:true}).isDisabled(),'Suspension lacks typed confirmation');await page.getByRole('button',{name:'Cancel',exact:true}).click();
 await page.setViewportSize({width:390,height:844});await page.screenshot({path:'.temp/access-admin-phone.png',fullPage:true});check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Admin page overflows a phone');
 await page.evaluate(()=>document.documentElement.dataset.theme='dark');await page.screenshot({path:'.temp/access-admin-dark-phone.png',fullPage:true});
 await page.getByRole('button',{name:'Enter as OWNER',exact:false}).first().click();await page.locator('.app-container').waitFor();await page.getByRole('button',{name:'Open navigation menu'}).click();await page.getByRole('button',{name:'Account: Platform administrator'}).click();await page.getByRole('menuitem',{name:'Return to admin panel'}).click();await page.getByRole('heading',{name:'Platform overview'}).waitFor();check(workspace===null,'Returning to admin retained a business context');
 mode='owner';await page.goto(base+'/#/users');await page.reload();await page.getByRole('heading',{name:'User & Access Management'}).waitFor();check(await page.getByRole('button',{name:'Create account',exact:true}).isVisible(),'Owner lacks access management');
 mode='staff';await page.reload();await page.getByRole('heading',{name:'Workspace access unavailable'}).waitFor();check(await page.getByRole('button',{name:'Create account',exact:true}).count()===0,'Staff can reach account-management UI');
 mode='admin';forced=true;await page.goto(base+'/#/admin');await page.reload();await page.getByRole('heading',{name:'Set your own password'}).waitFor();check(await page.getByRole('heading',{name:'Platform overview'}).count()===0,'Forced password page can be bypassed');
 check(errors.length===0,errors.join('\n'));
 return {passed:true,checks:'desktop/phone, light/dark, admin metrics/business/users/storage/backup, permission dependencies, owner-only exclusions, server account creation, suspension confirmation, admin entry/return, staff denial and mandatory password routing',errors};
}
