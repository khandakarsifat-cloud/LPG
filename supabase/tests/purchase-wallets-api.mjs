// Explicit live acceptance on the configured backend, using disposable businesses.
// The named burner account is read-only: its existing tenant is never repurposed.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync, existsSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
const azure=process.argv.includes('--azure');
assert(azure,'Use --azure to explicitly select the established deployment.');
const frontend=parseEnv(readFileSync('deploy/.env.frontend','utf8')), config=parseEnv(readFileSync('deploy/.env.backend','utf8'));
const url=frontend.VITE_SUPABASE_URL,key=frontend.VITE_SUPABASE_ANON_KEY,worker='https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(url,'https://api.lpg.20.40.48.3.sslip.io');assert.equal(config.AZURE_PROJECT_DIR,'/opt/lpg');
const ssh=['-i',config.AZURE_SSH_KEY,'-p',config.AZURE_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${config.AZURE_USER}@${config.AZURE_HOST}`];
const sql=q=>execFileSync('ssh',[...ssh,'cd /opt/lpg && sudo docker compose -p lpg -f compose.yml -f compose.azure.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input:q,encoding:'utf8'}).trim();
const uuid=x=>{assert.match(x,/^[0-9a-f-]{36}$/i);return `'${x}'::uuid`;};
const client=()=>createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async request=>{const {data,error}=await request;if(error)throw Error(`${error.code}: ${error.message}`);return data;};
const denied=async(request,pattern)=>{const {error}=await request;assert(error,'Expected rejection');if(pattern)assert.match(error.message,pattern);};
const users=[],tenants=[],clients=[];
const preserveQuery="select jsonb_build_object('wallets',(select jsonb_agg(jsonb_build_array(tenant_id,wallet_id,balance) order by tenant_id,wallet_id) from public.wallets),'ledger',(select md5(jsonb_agg(jsonb_build_array(tenant_id,transaction_id,wallet_id,amount,type,reference_id,description,created_at) order by tenant_id,transaction_id)::text) from public.wallet_transactions),'stock',(select md5(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text) from public.items i),'lines',(select md5(jsonb_agg(to_jsonb(i) order by tenant_id,purchase_item_id)::text) from public.purchase_items i),'transits',(select md5(jsonb_agg(to_jsonb(t) order by tenant_id,transit_id)::text) from public.transits t),'sales',(select count(*) from public.sales));";
const before=sql(preserveQuery);
async function account(label,setup=true){const c=client();clients.push(c);const auth=await checked(c.auth.signUp({email:`purchase-wallet-${label}-${randomUUID()}@example.invalid`,password:randomUUID()+'Aa1!'}));assert(auth.session);users.push(auth.user.id);let tenant;
 if(setup){tenant=(await checked(c.rpc('setup_business',{p_business_name:'Purchase wallet API fixture '+label,p_owner_name:'Fixture owner'}))).tenant_id;tenants.push(tenant);}return {client:c,user:auth.user.id,tenant,session:auth.session};}
let browser;
try{
 const owner=await account('owner'),other=await account('other'),manager=await account('manager',false);
 sql(`insert into public.user_profiles(user_id,tenant_id,email,full_name) select id,${uuid(owner.tenant)},email,'Fixture manager' from auth.users where id=${uuid(manager.user)};insert into public.user_roles(tenant_id,user_id,role_id) select tenant_id,${uuid(manager.user)},role_id from public.roles where tenant_id=${uuid(owner.tenant)} and name='MANAGER';`);
 const c=owner.client, rpc=(name,args)=>checked(c.rpc(name,args));
 const wallets=await checked(c.from('wallets').select('*'));const cash=wallets.find(w=>w.type==='cash'),bk=wallets.find(w=>w.type==='bkash'),bank=wallets.find(w=>w.type==='dealership'),ng=wallets.find(w=>w.type==='nagad');
 const custom=await rpc('save_finance_wallet',{p_payload:{name:'Fixture custom bank',kind:'bank',details:'Disposable acceptance'}});
 const otherCash=(await checked(other.client.rpc('get_payment_wallets')))[0].wallet_id;
 const brand=randomUUID(),plant=randomUUID(),truck=randomUUID(),sku=randomUUID();
 sql(`insert into public.lpg_brands(tenant_id,brand_id,brand_name)values(${uuid(owner.tenant)},${uuid(brand)},'Fixture LPG');insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name)values(${uuid(owner.tenant)},${uuid(plant)},${uuid(brand)},'Fixture plant');insert into public.trucks(tenant_id,truck_id,name,serial_no,capacity,size)values(${uuid(owner.tenant)},${uuid(truck)},'Fixture truck','Fixture truck',100,'medium');insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,filled_quantity,empty_quantity)values(${uuid(owner.tenant)},${uuid(sku)},${uuid(brand)},'Fixture LPG',12,20,20);`);
 const create=async note=>(await rpc('create_purchase',{p_payload:{plant_id:plant,truck_id:truck,request_id:randomUUID(),transport_cost:100,labour_cost:50,commission:100,notes:note,items:[{item_id:sku,type:'refill',quantity:1,empty_dispatched:1,unit_price:1000}]}})).purchase_id;
 const header=async id=>(await rpc('get_purchases_by_ids',{p_ids:[id]}))[0];
 const settle=id=>rpc('get_purchase_settlement',{p_purchase_id:id});
 const pay=(id,payments,request=randomUUID())=>rpc('record_purchase_payment',{p_purchase_id:id,p_payments:payments,p_request_id:request});
 const cancel=async id=>{const p=await header(id);return rpc('initiate_purchase_cancellation',{p_purchase_id:id,p_revision:p.revision,p_confirmation:'CANCEL',p_request_id:randomUUID()});};
 const refund=(id,o,payments,request=randomUUID())=>rpc('refund_purchase',{p_purchase_id:id,p_obligation_id:o,p_payments:payments,p_request_id:request});
 const p=await create('Partial split cancellation fixture');await rpc('dispatch_purchase',{p_purchase_id:p,p_revision:1});
 const split=[{wallet_id:cash.wallet_id,amount:200},{wallet_id:bk.wallet_id,amount:100,reference:'LIVE-PURCHASE-BK'}],request=randomUUID();
 const duplicate=await Promise.all(Array.from({length:3},()=>pay(p,split,request)));assert(duplicate.every(x=>x.paid_amount===400&&x.due===650));
 await denied(c.rpc('record_purchase_payment',{p_purchase_id:p,p_payments:[{wallet_id:cash.wallet_id,amount:10},{wallet_id:otherCash,amount:10}],p_request_id:randomUUID()}),/active.*wallet/i);assert.equal((await settle(p)).paid,400);
 await denied(c.rpc('update_purchase',{p_purchase_id:p,p_revision:(await header(p)).revision,p_payload:{labour_cost:51}}),/lock/i);
 await denied(c.rpc('record_purchase_payment',{p_purchase_id:p,p_payments:[{wallet_id:cash.wallet_id,amount:651}],p_request_id:randomUUID()}),/exceed/i);
 await denied(manager.client.rpc('initiate_purchase_cancellation',{p_purchase_id:p,p_revision:(await header(p)).revision,p_confirmation:'CANCEL',p_request_id:randomUUID()}),/OWNER/);
 await denied(c.rpc('initiate_purchase_cancellation',{p_purchase_id:p,p_revision:(await header(p)).revision,p_confirmation:'cancel',p_request_id:randomUUID()}),/exactly/);
 const transit=(await rpc('list_transits',{})).find(t=>t.purchase_id===p);await rpc('save_transit_costs',{p_transit_id:transit.transit_id,p_revision:transit.revision,p_costs:{driver_cost:15,helper_cost:0,oil_cost:0,others_cost:0}});
 const cancelled=await cancel(p);assert.equal(cancelled.refund_due,400);await rpc('transition_transit',{p_transit_id:transit.transit_id,p_revision:3,p_action:'close'});
 let state=await settle(p);const company=state.obligations.find(o=>o.component==='company');const refKey=randomUUID();
 const partialRefund=[{wallet_id:custom,amount:50},{wallet_id:cash.wallet_id,amount:50}];
 const retries=await Promise.all(Array.from({length:3},()=>refund(p,company.obligation_id,partialRefund,refKey)));assert(retries.every(r=>r.refund_due===300));
 await denied(c.rpc('refund_purchase',{p_purchase_id:p,p_obligation_id:company.obligation_id,p_payments:[{wallet_id:ng.wallet_id,amount:201}],p_request_id:randomUUID()}),/exceeds/);
 state=await settle(p);for(const o of state.obligations)if(o.remaining>0)await refund(p,o.obligation_id,[{wallet_id:ng.wallet_id,amount:o.remaining}]);
 assert((await settle(p)).financial_closed_at);assert.equal((await checked(c.from('wallets').select('*'))).find(w=>w.type==='logistics').balance,-15);
 const p2=await create('Full payment cancellation fixture');await rpc('dispatch_purchase',{p_purchase_id:p2,p_revision:1});await pay(p2,[{wallet_id:bank.wallet_id,amount:950}]);assert.equal((await settle(p2)).due,0);await cancel(p2);for(const o of (await settle(p2)).obligations)await refund(p2,o.obligation_id,[{wallet_id:custom,amount:o.remaining}]);assert((await settle(p2)).financial_closed_at);
 const p3=await create('Received payment-independent fixture');await rpc('dispatch_purchase',{p_purchase_id:p3,p_revision:1});await pay(p3,[{wallet_id:cash.wallet_id,amount:40}]);await rpc('receive_purchase',{p_purchase_id:p3,p_revision:(await header(p3)).revision});await denied(c.rpc('initiate_purchase_cancellation',{p_purchase_id:p3,p_revision:(await header(p3)).revision,p_confirmation:'CANCEL',p_request_id:randomUUID()}),/never/);await pay(p3,[{wallet_id:custom,amount:910}]);assert.equal((await settle(p3)).paid,1050);
 const draft=await create('Unfunded draft fixture');assert((await cancel(draft)).financially_closed);
 await denied(other.client.rpc('get_purchase_settlement',{p_purchase_id:p}),/not found/);await denied(other.client.rpc('record_purchase_payment',{p_purchase_id:p3,p_payments:split,p_request_id:randomUUID()}),/not found/);
 await rpc('save_finance_wallet',{p_payload:{wallet_id:cash.wallet_id,revision:1,name:'Renamed fixture cash',kind:'cash',is_active:true}});assert((await settle(p)).payments.some(e=>e.wallet_name==='Cash Register'));
 assert.equal(sql(`select count(*) from public.wallets w where tenant_id=${uuid(owner.tenant)} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)`),'0');
 console.log('PASS: real Auth/PostgREST split/full/additional payments, confirmation/OWNER/receipt boundaries, partial multi-wallet refunds, transport expense reconciliation, snapshot names, retries, rollback and cross-tenant denial.');
 if(process.argv.includes('--browser')){
  const {chromium}=await import('playwright');browser=await chromium.launch({channel:'chrome',headless:true});mkdirSync('.temp/purchase-wallets',{recursive:true});
  const p4=await create('Authenticated browser lifecycle fixture');await rpc('dispatch_purchase',{p_purchase_id:p4,p_revision:1});
  const context=await browser.newContext({viewport:{width:1440,height:950}});await context.addInitScript(s=>localStorage.setItem('sb-api-auth-token',JSON.stringify(s)),owner.session);const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(worker+'/?purchase-live-fixture=1#/purchases');await page.locator(`[data-purchase-id="${p4}"]`).click();const details=page.getByRole('dialog',{name:'Purchase details',exact:true});
  await details.getByRole('button',{name:'Record payment',exact:true}).click();const payment=page.getByRole('dialog',{name:'Pay purchase',exact:true});await payment.getByRole('button',{name:'Add payment',exact:true}).click();await payment.getByLabel('Payment 1 wallet',{exact:true}).selectOption(bk.wallet_id);await payment.getByLabel('Payment 1 amount',{exact:true}).fill('150');await payment.getByLabel('Payment 1 reference',{exact:true}).fill('LIVE-BROWSER-150');
  for(const width of [390,768,1440]){await page.setViewportSize({width,height:950});assert(await payment.evaluate(e=>e.scrollWidth<=e.clientWidth));await page.screenshot({path:`.temp/purchase-wallets/live-payment-${width}.png`});}
  await payment.getByRole('button',{name:'Record payment',exact:true}).click();await payment.waitFor({state:'hidden'});assert.equal((await settle(p4)).paid,250);
  await details.getByRole('button',{name:'Cancel purchase',exact:true}).click();const confirmation=page.getByRole('dialog',{name:'Cancel this purchase?',exact:true});await confirmation.getByLabel('Type exactly CANCEL').fill('CANCEL');await confirmation.getByRole('button',{name:'Confirm cancellation',exact:true}).click();await confirmation.waitFor({state:'hidden'});
  while((await settle(p4)).refund_due>0){await details.getByRole('button',{name:'Record refund',exact:true}).click();const dialog=page.getByRole('dialog',{name:'Record purchase refund',exact:true});await dialog.getByRole('button',{name:/Refund remaining/}).click();await dialog.getByLabel('Payment 1 wallet',{exact:true}).selectOption(custom);await dialog.getByRole('button',{name:'Record refund',exact:true}).click();await dialog.waitFor({state:'hidden'});}
  await details.getByText(/Financially closed:/).waitFor();assert.equal(errors.length,0);await context.close();console.log('PASS: published real payment/cancellation/refund closure in an isolated business at desktop/tablet/phone widths.');
  const secrets={...(existsSync('.env.live-test')?parseEnv(readFileSync('.env.live-test','utf8')):{}),...process.env};assert(secrets.LPG_TEST_EMAIL&&secrets.LPG_TEST_PASSWORD,'Provide ignored burner credentials');
  const burner=await browser.newContext({viewport:{width:1440,height:950}});let forbidden=0;await burner.route('**/rest/v1/**',async r=>{const request=r.request(),name=new URL(request.url()).pathname.split('/').pop();if(request.method()==='POST'&&!/^(get_|list_)/.test(name)){forbidden++;await r.abort();}else await r.continue();});
  const readPage=await burner.newPage();await readPage.goto(worker+'/?burner-read-only=1#/login');await readPage.getByLabel('Email Address',{exact:true}).fill(secrets.LPG_TEST_EMAIL);await readPage.getByLabel('Password',{exact:true}).fill(secrets.LPG_TEST_PASSWORD);await readPage.getByRole('button',{name:'Sign In',exact:true}).click();await readPage.waitForURL(u=>u.hash!=='#/login');await readPage.goto(worker+'/?burner-read-only=2#/purchases');await readPage.locator('.purchase-card').first().waitFor();
  for(const width of [390,768,1440]){await readPage.setViewportSize({width,height:950});await readPage.locator('.purchase-card').first().click();await readPage.getByText('Payments & refunds',{exact:true}).waitFor();await readPage.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click();}
  assert.equal(forbidden,0);await burner.close();console.log('PASS: published authenticated purchase payment/cancellation/refund flows at desktop/tablet/phone widths in a disposable business; burner form login and read-only purchase details at all three widths.');
 }
}catch(error){
 let message=error instanceof Error?error.message:String(error);
 const secretConfig={...(existsSync('.env.live-test')?parseEnv(readFileSync('.env.live-test','utf8')):{}),...process.env};
 if(secretConfig.LPG_TEST_PASSWORD)message=message.replaceAll(secretConfig.LPG_TEST_PASSWORD,'[redacted]');
 console.error('Live purchase acceptance failed: '+message);process.exitCode=1;
}finally{
 if(browser)await browser.close();
 for(const c of clients)await c.auth.signOut({scope:'local'}).catch(()=>{});
 if(tenants.length){const ids=tenants.map(uuid).join(',');const tables=['finance_requests','wallet_transactions','customer_transactions','sale_payments','purchase_payments','purchase_refund_obligations','purchase_activity','sale_items','sales','inventory_movements','purchase_items','transits','purchases','product_commission_rates','price_books','items','area_officers','gas_plants','lpg_brands','trucks','customers','receipt_printers','wallets','user_roles','role_permissions','roles','audit_logs','user_profiles','tenants'];
  // Privileged, session-local fixture teardown only. Genuine tenants are guarded
  // before disabling triggers in this session; no schema trigger is disabled globally.
  sql(`begin;do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Purchase wallet API fixture %') then raise exception 'Not a disposable purchase fixture';end if;end$$;set local session_replication_role=replica;${tables.map(t=>`delete from public.${t} where tenant_id in (${ids});`).join('\n')}commit;`);
 }
 if(users.length)sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
 assert.equal(sql(preserveQuery),before,'Original business stock, wallets, ledger, purchase lines, transits and sales must remain unchanged');console.log('Removed only new fixture businesses/accounts; original business hashes unchanged.');
}
