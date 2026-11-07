// Isolated real Auth/PostgREST acceptance. No genuine business is adopted or modified.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFileSync,writeFileSync,mkdirSync,existsSync,unlinkSync,copyFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {parseEnv} from 'node:util';
import {createClient} from '@supabase/supabase-js';
import {provisionTestBusiness} from './trusted-test-provisioning.mjs';
assert(process.argv.includes('--vps'));
const f=parseEnv(readFileSync('deploy/.env.frontend','utf8')),b=parseEnv(readFileSync('deploy/.env.backend','utf8'));
assert.equal(f.VITE_SUPABASE_URL,'https://api.lpg.144.79.249.4.sslip.io');assert.equal(b.VPS_HOST,'144.79.249.4');
const folder='.temp/finance-visibility-live';mkdirSync(folder,{recursive:true});
const file=`${folder}/manifest.json`,credentials=`${folder}/credentials.json`;
let m=existsSync(file)?JSON.parse(readFileSync(file,'utf8')):{business_name:`Finance visibility disposable acceptance ${randomUUID()}`,events:{}};
if(m.cleaned_at&&!process.argv.includes('--cleanup')&&!process.argv.includes('--verify')){
 copyFileSync(file,`${folder}/completed-${m.tenant_id}.json`);
 m={business_name:`Finance visibility disposable acceptance ${randomUUID()}`,events:{}};
}
const persist=()=>writeFileSync(file,JSON.stringify(m,null,2));
const c=createClient(f.VITE_SUPABASE_URL,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async p=>{const {data,error}=await p;if(error)throw Error(error.message);return data;};
const report=()=>checked(c.rpc('get_product_performance',{p_business:'lpg'}));
const quantities=async()=>Object.fromEntries((await report()).rows.flatMap(row=>[[`bought_${row.type}`,row.bought],[`sold_${row.type}`,row.sold]]));
const ssh=[...(b.VPS_SSH_KEY?['-i',b.VPS_SSH_KEY]:[]),'-p',b.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${b.VPS_USER}@${b.VPS_HOST}`];
const sql=input=>execFileSync('ssh',[...ssh,'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
const uid=id=>{assert.match(id,/^[0-9a-f-]{36}$/);return `'${id}'::uuid`;};
assert(!m.cleaned_at,'Fixture already cleaned; archive its evidence before starting a new run');
let secrets=existsSync(credentials)?JSON.parse(readFileSync(credentials,'utf8')):{owner:{email:`finance-owner-${randomUUID()}@example.invalid`,password:randomUUID()+'Aa9!'},staff:{email:`finance-staff-${randomUUID()}@example.invalid`,password:randomUUID()+'Aa9!'}};
if(!m.tenant_id){writeFileSync(credentials,JSON.stringify(secrets));const fixture=await provisionTestBusiness(c,{...secrets.owner,businessName:m.business_name,ownerName:'Finance acceptance owner'});m.tenant_id=fixture.tenant_id;m.owner_id=fixture.user.id;persist();}
else await checked(c.auth.signInWithPassword(secrets.owner));
assert.equal((await checked(c.rpc('get_access_context'))).tenant_id,m.tenant_id);
const run=async(key,name,args)=>{if(m.events[key]?.completed)return m.events[key].result;m.events[key]??={name,args};persist();const result=await checked(c.rpc(name,m.events[key].args));Object.assign(m.events[key],{completed:true,result});persist();return result;};
try{
 if(process.argv.includes('--cleanup')){
  assert(m.verified_at&&m.browser_at,'API and published browser verification required before cleanup');
  await c.auth.signOut({scope:'global'});
  const tables=sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1").split('\n');assert(tables.every(t=>/^(public|app_private)\.[a-z_]+$/.test(t)));
  sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id=${uid(m.tenant_id)} and p.user_id=${uid(m.owner_id)} and t.business_name like 'Finance visibility disposable acceptance %') then raise exception 'Non-fixture cleanup refused';end if;end$$;set local session_replication_role=replica;${tables.map(t=>`delete from ${t} where tenant_id=${uid(m.tenant_id)};`).join('\n')}set local session_replication_role=origin;delete from auth.users where id in (${uid(m.owner_id)},${uid(m.staff_id)});commit;`);
  m.cleaned_at=new Date().toISOString();persist();unlinkSync(credentials);console.log('PASS only the exact verified Finance fixture business and its generated identities removed');
 }else if(process.argv.includes('--verify')){
  assert(m.browser_at);
  const wallets=await checked(c.rpc('get_finance_wallets'));assert.equal(Number(wallets.find(w=>w.wallet_id===m.cash).balance),-37.5);
  assert.equal((await checked(c.rpc('get_financial_entries'))).total,2);
  assert.deepEqual(await quantities(),{bought_refill:70,bought_package:30,sold_refill:2,sold_package:1});
  const fifo=await checked(c.rpc('get_fifo_stock',{p_item_id:m.item}));assert.equal(fifo.summary.gas,97);assert.equal((fifo.summary.bottle-fifo.summary.gas),1);
  const accounting=JSON.parse(sql(`select jsonb_build_object('wallets',(select coalesce(sum(balance),0) from public.wallets where tenant_id=${uid(m.tenant_id)}),'cash',(select coalesce(sum(amount),0) from public.accounting_lines where tenant_id=${uid(m.tenant_id)} and account='cash'),'bad_journals',(select count(*) from(select journal_id from public.accounting_lines where tenant_id=${uid(m.tenant_id)} group by journal_id having sum(amount)<>0)x),'bad_wallets',(select count(*) from public.wallets w where tenant_id=${uid(m.tenant_id)} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)),'stock',(select sum(remaining_value+remaining_internal_value) from app_private.fifo_layers where tenant_id=${uid(m.tenant_id)}),'inventory_journal',(select sum(amount) from public.accounting_lines where tenant_id=${uid(m.tenant_id)} and account='inventory_lpg'));`));
  assert.equal(accounting.wallets,accounting.cash);assert.equal(accounting.bad_journals,0);assert.equal(accounting.bad_wallets,0);assert.equal(accounting.stock,accounting.inventory_journal);
  assert.equal(fifo.total,fifo.layers.length,'This fixture fits one component page');
  assert.equal(accounting.stock,fifo.layers.reduce((sum,layer)=>sum+Number(layer.carrying_value),0));
  m.reconciliation=accounting;m.verified_at=new Date().toISOString();persist();console.log('PASS real source quantities, FIFO carrying assets, wallet ledgers/Cash and every journal reconcile independently');
 }else{
  m.cash=(await checked(c.rpc('get_payment_wallets'))).find(w=>w.type==='cash').wallet_id;m.bank=(await checked(c.rpc('get_payment_wallets'))).find(w=>w.type==='dealership').wallet_id;persist();
  if(!m.staff_id){
   const session=(await c.auth.getSession()).data.session;
   m.staff_request??=randomUUID();persist();
   const r=await fetch(`${f.VITE_SUPABASE_URL}/accounts/v1/provision`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${session.access_token}`},body:JSON.stringify({request_id:m.staff_request,operation:{kind:'user',tenant_id:m.tenant_id,name:'Finance acceptance staff',email:secrets.staff.email,role:'MANAGER'},password:secrets.staff.password})});const result=await r.json();assert(r.ok,result.error);m.staff_id=result.user_id;persist();
   const staff=createClient(f.VITE_SUPABASE_URL,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});await checked(staff.auth.signInWithPassword(secrets.staff));
   const token=(await staff.auth.getSession()).data.session.access_token;
   const changed={...secrets.staff,password:randomUUID()+'Aa9!'};
   writeFileSync(`${folder}/pending-password.json`,JSON.stringify(changed));
   const change=await fetch(`${f.VITE_SUPABASE_URL}/accounts/v1/password`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${token}`},body:JSON.stringify({current_password:secrets.staff.password,password:changed.password})});assert(change.ok,'Normal first-login password change');secrets.staff=changed;writeFileSync(credentials,JSON.stringify(secrets));unlinkSync(`${folder}/pending-password.json`);await staff.auth.signOut({scope:'local'});
  }
  const brand=await run('brand','create_lpg_brand',{p_brand_name:'Jamuna acceptance'});m.brand=brand.brand_id??brand;
  if(!m.item){m.item=(await checked(c.from('items').insert({tenant_id:m.tenant_id,brand_id:m.brand,size_kg:12,mouth_size:'22mm'}).select('item_id').single())).item_id;persist();}
  m.plant=(await run('plant','create_gas_plant',{p_plant_name:'Performance acceptance plant',p_brand_id:m.brand,p_location:'Dhaka'})).plant_id;
  m.driver=(await run('driver','save_employee',{p_payload:{name:'Performance acceptance Driver',employee_type_name:'Driver',business_unit:'truck_business',phones:[{phone:'01799000555',is_primary:true}],terms:{effective_from:new Date().toLocaleDateString('en-CA',{timeZone:'Asia/Dhaka'}),monthly_salary:0,is_active:true}},p_request_id:randomUUID()})).employee_id;
  m.truck=(await run('truck','save_vehicle',{p_payload:{name:'Performance acceptance truck',serial_no:'FINANCE-ACCEPTANCE',capacity:200,driver_employee_id:m.driver,book_value:10000,funding:'capital'},p_request_id:randomUUID()})).vehicle_id;persist();
  await run('empties','adjust_inventory',{p_payload:{item_id:m.item,kind:'capital',bottle_quantity:70,bottle_unit_cost:1200,reason:'Historical owned cylinders'},p_request_id:randomUUID()});
  m.purchase=(await run('purchase','create_purchase',{p_payload:{request_id:randomUUID(),plant_id:m.plant,vehicle_id:m.truck,transport_cost:2600,labour_cost:1300,items:[{item_id:m.item,quantity:100,bottle_quantity:30,unit_price:800,bottle_unit_price:1600}]}})).purchase_id;persist();
  const detail=async()=> (await checked(c.rpc('get_purchases_by_ids',{p_ids:[m.purchase]})))[0];
  await run('dispatch','dispatch_purchase',{p_purchase_id:m.purchase,p_revision:(await detail()).revision});
  assert.equal((await quantities()).bought_refill,m.events.receive?.completed?70:0);
  await run('receive','receive_purchase',{p_purchase_id:m.purchase,p_revision:(await detail()).revision});
  await run('prices','save_product_prices',{p_item_id:m.item,p_customer_tier:'retail',p_prices:{refill:{price:1250,mrp:null},package:{price:3000,mrp:null}},p_expected:{refill:null,package:null}});
  await run('sale','create_pos_sale',{p_customer_phone:'01799000556',p_customer_name:'Performance buyer',p_customer_shop_name:null,p_customer_address:'Dhaka',p_customer_tier:'retail',p_discount_amount:0,p_exchange_fee:0,p_notes:'Performance and unsettled bottle acceptance',p_bottles:{lines:[{received_item_id:m.item,quantity:1}]},p_items:[{item_id:m.item,type:'refill',quantity:2,unit_price:1250},{item_id:m.item,type:'package',quantity:1,unit_price:3000}],p_payments:[],p_request_id:randomUUID()});
  const catalog=await checked(c.rpc('get_financial_catalog'));m.expense_type=catalog.types.find(x=>x.name==='Visibility acceptance expense')?.type_id??(await run('expense-type','save_financial_type',{p_payload:{name:'Visibility acceptance expense',account:'operating_expense',allocations:{lpg:100},is_active:true}})).type_id;
  await run('owner-entry','record_financial_entry',{p_payload:{type_id:m.expense_type,expected_revision:1,wallet_id:m.bank,amount:10,date:new Date().toLocaleDateString('en-CA',{timeZone:'Asia/Dhaka'}),description:'Owner separate entry'},p_request_id:randomUUID()});
  assert.deepEqual(await quantities(),{bought_refill:70,bought_package:30,sold_refill:2,sold_package:1});
  const fifo=await checked(c.rpc('get_fifo_stock',{p_item_id:m.item}));assert.equal(fifo.summary.gas,97);assert.equal((fifo.summary.bottle-fifo.summary.gas),1);assert.equal((await checked(c.rpc('get_fifo_stock',{p_item_id:m.item,p_tier:'wholesale'}))).layers[0].projected_margin,fifo.layers[0].projected_margin);
  m.setup_at=new Date().toISOString();persist();console.log('PASS actual Auth owner/staff provisioning, purchase dispatch/receipt, mixed Refill/Package sale and independent report/FIFO quantities; ready for published browser');
 }
}finally{await c.auth.signOut({scope:'local'});}
