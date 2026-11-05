// Normal Auth/PostgREST, isolated retained business, recoverable source manifest.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {existsSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {createClient} from '@supabase/supabase-js';
import {calculateFinancialSources} from './financial-independent.mjs';
assert(process.argv.includes('--vps'),'Explicit --vps required');
const config=parseEnv(readFileSync('deploy/.env.frontend','utf8')),api='https://api.lpg.144.79.249.4.sslip.io';assert.equal(config.VITE_SUPABASE_URL,api);
const folder='.temp/financial-business';mkdirSync(folder,{recursive:true});const path=folder+'/manifest.json';
const m=existsSync(path)?JSON.parse(readFileSync(path,'utf8')):{steps:{},events:[]};const save=()=>writeFileSync(path,JSON.stringify(m,null,2));
const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date());assert(today>='2026-11-01');
const c=createClient(api,config.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async promise=>{const{data,error}=await promise;if(error)throw Error(`${error.code??'API'}: ${error.message}`);return data;};
let secret;
if(existsSync('.env.financial-test')){secret=parseEnv(readFileSync('.env.financial-test','utf8'));await checked(c.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));}
else{assert(process.argv.includes('--create'),'Use --create to create the isolated retained account');secret={LPG_TEST_EMAIL:`lpg-financial-20261101-${randomUUID().slice(0,8)}@example.invalid`,LPG_TEST_PASSWORD:randomUUID()+'Aa1!'};const auth=await checked(c.auth.signUp({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));assert(auth.session);m.user=auth.user.id;writeFileSync('.env.financial-test',Object.entries(secret).map(([k,v])=>`${k}=${v}`).join('\n')+'\n',{mode:0o600});save();}
async function rpc(label,name,args){if(m.steps[label]?.done)return m.steps[label].result;const step=m.steps[label]??={request:randomUUID()};save();if(args.p_request_id===true)args={...args,p_request_id:step.request};if(name==='create_purchase')args={...args,p_payload:{...args.p_payload,request_id:step.request}};const result=await checked(c.rpc(name,args));step.done=true;step.result=result;save();return result;}
const op=(label,payload)=>rpc(label,'accounting_operation',{p_payload:payload,p_request_id:true});
function event(label,data){if(!m.events.some(e=>e.label===label)){m.events.push({label,order:m.events.length,...data});save();}}
const initial=await checked(c.from('user_profiles').select('tenant_id,tenants(business_name)').eq('user_id',(await c.auth.getUser()).data.user.id).maybeSingle());if(initial)assert.equal(initial.tenants.business_name,'LPG Unified Financial Development Lab 2026-11-01','Refuse to repurpose an unrelated existing business');
const business=await rpc('setup','setup_business',{p_business_name:'LPG Unified Financial Development Lab 2026-11-01',p_owner_name:'Unified financial development operator'});m.tenant=business.tenant_id;save();
const profile=await checked(c.from('user_profiles').select('tenant_id,tenants(business_name)').eq('user_id',(await c.auth.getUser()).data.user.id).single());assert.equal(profile.tenant_id,m.tenant);assert.equal(profile.tenants.business_name,'LPG Unified Financial Development Lab 2026-11-01');
if(!m.seedComplete){
 const wallets=await checked(c.rpc('get_payment_wallets'));const cash=wallets.find(w=>w.type==='cash').wallet_id,bank=wallets.find(w=>w.type==='dealership').wallet_id;m.cash=cash;m.bank=bank;save();
 for(const[label,w,alloc]of[['cash',cash,{lpg:60,stove:20,logistics:20}],['bank',bank,{lpg:80,stove:20}]]){await op('fund-'+label,{action:'capital',wallet_id:w,amount:300000,date:'2026-08-01',description:'Explicit development opening investment',allocations:alloc});event('fund-'+label,{kind:'funding',wallet:w,amount:300000,date:'2026-08-01',allocations:alloc});}
 const crew=[];for(const[index,role]of['Driver','Helper'].entries())crew.push((await rpc('crew-'+role,'save_employee',{p_payload:{name:'Financial lab '+role,employee_type_name:role,business_unit:'truck_business',phones:[{phone:'0178800099'+index,is_primary:true}],terms:{effective_from:'2026-08-01',monthly_salary:0,is_active:true}},p_request_id:true})).employee_id);
 const truck=await rpc('truck','save_vehicle',{p_payload:{name:'Financial lab truck',serial_no:'FIN-LAB-01',capacity:100,book_value:200000,funding:'opening',acquired_on:'2026-08-01',driver_employee_id:crew[0],helper_employee_id:crew[1]},p_request_id:true});m.truck=truck.vehicle_id;save();
 const truckDetail=await checked(c.rpc('get_vehicle',{p_vehicle_id:m.truck}));event('truck',{kind:'asset',id:truckDetail.asset.asset_id,account:'vehicles',funding:'opening',amount:200000,allocations:{logistics:100},date:'2026-08-01'});
 // Brand management uses its existing owner-gated catalog write.
 if(!m.brand){const brands=await checked(c.from('lpg_brands').select('brand_id,brand_name'));if(brands.length)m.brand=brands[0].brand_id;else{const b=await rpc('brand','create_lpg_brand',{p_brand_name:'Financial lab supplier',p_description:'Retained financial acceptance supplier'});m.brand=b.brand_id;}save();}
 const plant=await rpc('plant','create_gas_plant',{p_plant_name:'Financial lab plant',p_brand_id:m.brand,p_location:'Dhaka'});m.plant=plant.plant_id;save();
 if(!m.lpg){const row=await checked(c.from('items').insert({tenant_id:m.tenant,brand_id:m.brand,size_kg:12,mouth_size:'22mm'}).select('item_id').single());m.lpg=row.item_id;save();}
 const stoveTypes=await checked(c.rpc('get_stove_product_types'));m.stove=(await rpc('stove','save_stove_product',{p_payload:{name:'Financial lab stove',type_id:stoveTypes[0].type_id},p_request_id:true})).item_id;save();
 for(const[item,price,gas]of[[m.lpg,4000,true],[m.stove,1500,false]]){const current=await checked(c.rpc('get_product_inventory',{p_item_id:item}));const expected={refill:current.prices.find(p=>p.customer_tier==='retail'&&p.price_type==='refill')?.effective_from??null,package:current.prices.find(p=>p.customer_tier==='retail'&&p.price_type==='package')?.effective_from??null};await rpc('prices-'+item,'save_product_prices',{p_item_id:item,p_customer_tier:'retail',p_prices:{refill:{price:gas?1500:0,mrp:null},package:{price,mrp:null}},p_expected:expected});}
 for(const[name,account,allocations]of[['Electricity','operating_expense',{lpg:70,stove:30}],['Home','withdrawals',{lpg:100}],['External delivery receipts','other_income',{logistics:100}],['Workshop equipment','equipment',{lpg:60,stove:40}]]){
  const existing=(await checked(c.rpc('get_financial_catalog'))).types.find(t=>t.origin==='custom'&&t.name===name);m.types??={};m.types[name]=existing??await rpc('type-'+name,'save_financial_type',{p_payload:{name,account,allocations}});if(!m.types[name].allocations)m.types[name]=(await checked(c.rpc('get_financial_catalog'))).types.find(t=>t.type_id===m.types[name].type_id);save();
 }
 const entry=async(label,name,amount,date,wallet= cash)=>{const type=m.types[name];return rpc(label,'record_financial_entry',{p_payload:{type_id:type.type_id,expected_revision:type.revision,wallet_id:wallet,amount,date,description:'Financial lab '+label},p_request_id:true});};
 const equipment=await entry('equipment','Workshop equipment',100000,'2026-08-02',bank);m.equipment=equipment.asset_id;save();event('equipment',{kind:'asset',id:m.equipment,account:'equipment',funding:'wallet',wallet:bank,amount:100000,allocations:{lpg:60,stove:40},date:'2026-08-02'});
 for(const[index,month]of['2026-08','2026-09','2026-10'].entries()){
  const date=month+'-04';const rate=await checked(c.rpc('get_monthly_commissions',{p_item_id:m.lpg,p_month:month+'-01'}));await rpc('rate-'+month,'set_monthly_commission',{p_payload:{item_id:m.lpg,month:month+'-01',package_rate:100,refill_rate:100,expected_revision:rate.current?.revision??0,reason:'Explicit development supplier confirmation'},p_request_id:true});
  for(const[b,item,unit,selling]of[['lpg',m.lpg,2500+index*100,4000],['stove',m.stove,1000+index*100,1500]]){
   const deduction=b==='lpg'&&index?600:0,transport=b==='lpg'?3000:0,label=month+'-'+b;
   const payload={business_category:b,items:[{item_id:item,type:'package',quantity:10,unit_price:unit,...(b==='lpg'?{shell_unit_cost:1500}:{})}],...(b==='lpg'?{plant_id:m.plant,vehicle_id:m.truck,commission:deduction,transport_cost:transport,transport_wallet_id:bank}:{supplier_name:'Financial lab stove manufacturer'})};
   const purchase=await rpc(label,'create_purchase',{p_payload:payload});if(b==='lpg')await rpc(label+'-dispatch','dispatch_purchase',{p_purchase_id:purchase.purchase_id,p_revision:1,p_dispatched_on:date});await rpc(label+'-receive','receive_purchase',{p_purchase_id:purchase.purchase_id,p_revision:b==='lpg'?2:1,p_received_on:date});
   event(label,{kind:'purchase',id:purchase.purchase_id,item,business:b,quantity:10,unit,rate:b==='lpg'?100:0,deduction,transport,wallet:bank,cash,brand:b==='lpg'?m.brand:'',date});
   const amount=(10*unit-deduction)/2;await rpc(label+'-pay','record_purchase_payment',{p_purchase_id:purchase.purchase_id,p_payments:[{wallet_id:bank,amount:amount/2},{wallet_id:cash,amount:amount/2}],p_request_id:true});for(const w of[bank,cash])event(label+'-pay-'+w,{kind:'purchasePayment',business:b,wallet:w,amount:amount/2,purchase:purchase.purchase_id,date:today});
   const payments=b==='lpg'?[{wallet_id:cash,amount:8000},{wallet_id:bank,amount:8000}]:[];
   const savedCustomer=await checked(c.from('customers').select('customer_id').eq('phone',b==='lpg'?'01788000101':'01788000102').maybeSingle());
   const sale=await rpc(label+'-sale','create_pos_sale',{p_customer_phone:b==='lpg'?'01788000101':'01788000102',p_customer_name:'Financial lab '+b+' buyer',p_customer_shop_name:null,p_customer_address:null,p_customer_tier:'retail',p_discount_amount:0,p_exchange_fee:0,p_notes:'Retained dimensional source invoice',p_items:[{item_id:item,type:'package',quantity:8,unit_price:selling}],p_customer_id:savedCustomer?.customer_id??null,p_request_id:true,p_payments:payments,p_bottles:null,p_sold_on:month+'-12'});
   const details=await checked(c.rpc('get_sale_receipt',{p_sale_id:sale.sale_id}));const customer=details.customer?.customer_id??details.sale?.customer_id??(await checked(c.from('sales').select('customer_id').eq('sale_id',sale.sale_id).single())).customer_id;
   event(label+'-sale',{kind:'sale',id:sale.sale_id,item,business:b,quantity:8,amount:8*selling,customer,payments:payments.map(p=>({wallet:p.wallet_id,amount:p.amount})),payment_date:today,date:month+'-12'});
   const received=b==='lpg'?8000:4000,w=b==='lpg'?cash:bank;await rpc(label+'-collection','collect_sale_payment',{p_sale_id:sale.sale_id,p_payments:[{wallet_id:w,amount:received}],p_request_id:true});event(label+'-collection',{kind:'collection',business:b,wallet:w,amount:received,customer,date:today});
  }
  for(const[name,amount,category,allocations]of[['Electricity',10000,'expense',{lpg:70,stove:30}],['Home',5000,'withdrawal',{lpg:100}],['External delivery receipts',2000,'revenue',{logistics:100}]]){await entry(month+'-'+name,name,amount,month+'-25');event(month+'-'+name,{kind:'custom',category,amount,allocations,wallet:cash,date:month+'-25'});}
  await op(month+'-depreciation',{action:'asset_depreciate',asset_id:m.equipment,amount:1000,date:month+'-28',description:'Explicit monthly workshop depreciation'});event(month+'-depreciation',{kind:'depreciation',id:m.equipment,account:'equipment',amount:1000,allocations:{lpg:60,stove:40},date:month+'-28'});
 }
 const loan=await op('loan',{action:'loan_create',lender:'Financial lab lender',wallet_id:bank,amount:50000,date:today,description:'Explicit development working capital',allocations:{lpg:100}});event('loan',{kind:'loan',id:loan.id,business:'lpg',wallet:bank,amount:50000,date:today});await op('loan-repay',{action:'loan_repay',loan_id:loan.id,wallet_id:bank,amount:10000,date:today,description:'Partial principal returned'});event('loan-repay',{kind:'loanRepay',id:loan.id,business:'lpg',wallet:bank,amount:10000,date:today});
 await op('improvement',{action:'asset_improve',asset_id:m.equipment,funding:'credit',amount:5000,date:today,description:'Qualifying workshop improvement'});event('improvement',{kind:'improvement',id:m.equipment,account:'equipment',amount:5000,allocations:{lpg:60,stove:40},date:today});
 for(const[label,b,w,db,dest,amount]of[['same-wallet','lpg',cash,'logistics',cash,20000],['negative-business','logistics',bank,'logistics',cash,10000]]){await rpc('transfer-'+label,'move_wallet_money',{p_payload:{action:'transfer',transfer_mode:'business',wallet_id:w,destination_id:dest,business:b,destination_business:db,amount,reason:'Financial lab '+label},p_request_id:true});event('transfer-'+label,{kind:'transfer',business:b,wallet:w,destination_business:db,destination:dest,amount,date:today});}
 m.seedComplete=true;save();console.log('PASS retained three-month dimensional business seeded through normal authenticated APIs');
}
// Historical invoices were entered now; checkout receipts keep today's actual
// cash date independently of the backdated sale recognition date.
for(const e of m.events)if(e.kind==='sale'&&!e.payment_date)e.payment_date=today;save();
if(!m.stoveDeliveryComplete){
 const purchase=await rpc('stove-internal-delivery','create_purchase',{p_payload:{business_category:'stove',supplier_name:'Financial lab delivered stove manufacturer',vehicle_id:m.truck,transport_cost:400,transport_wallet_id:m.bank,items:[{item_id:m.stove,type:'package',quantity:2,unit_price:1400}]}});
 await rpc('stove-internal-dispatch','dispatch_purchase',{p_purchase_id:purchase.purchase_id,p_revision:1,p_dispatched_on:today});
 await rpc('stove-internal-receive','receive_purchase',{p_purchase_id:purchase.purchase_id,p_revision:2,p_received_on:today});
 event('stove-internal-delivery',{kind:'purchase',id:purchase.purchase_id,item:m.stove,business:'stove',quantity:2,unit:1400,rate:0,deduction:0,transport:400,wallet:m.bank,cash:m.cash,date:today});
 const buyer=await checked(c.from('customers').select('customer_id').eq('phone','01788000102').single());
 const sale=await rpc('stove-delivered-sale','create_pos_sale',{p_customer_phone:'01788000102',p_customer_name:'Financial lab stove buyer',p_customer_shop_name:null,p_customer_address:null,p_customer_tier:'retail',p_discount_amount:0,p_exchange_fee:0,p_notes:'Original old and delivered Stove FIFO batches',p_items:[{item_id:m.stove,type:'package',quantity:7,unit_price:1500}],p_customer_id:buyer.customer_id,p_request_id:true,p_payments:[],p_bottles:null,p_sold_on:today});
 event('stove-delivered-sale',{kind:'sale',id:sale.sale_id,item:m.stove,business:'stove',quantity:7,amount:10500,customer:buyer.customer_id,payments:[],payment_date:today,date:today});
 m.stoveDeliveryComplete=true;save();
 console.log('PASS optional Stove internal delivery and mixed original-batch sale seeded through normal authenticated APIs');
}
const results=[];for(const to of['2026-08-31','2026-09-30','2026-10-31',today])for(const scope of['all','lpg','stove','logistics']){
 const expected=calculateFinancialSources(m.events,to,scope);const report=await checked(c.rpc('get_finance_analysis',{p_filters:{business_id:m.tenant,from:'2026-08-01',to,category:scope,grain:'month'}}));
 for(const key of['assets','liabilities','equity','cash','capital','revenue','expenses','withdrawals','other_equity','accumulated_income'])assert.equal(Math.round(report.closing[key]*100),expected[key],`${to}/${scope}/${key}`);
 const acquisitions=m.events.filter(e=>e.kind==='purchase'&&e.date<=to&&(scope==='all'||e.business===scope)).reduce((sum,e)=>sum+e.quantity*(e.unit-e.rate)+(scope==='all'?0:e.transport??0),0);assert.equal(Math.round(report.period_values.stock_acquisitions*100),Math.round(acquisitions*100),`${to}/${scope}/new acquisition cost`);
 assert.equal(Math.round(report.totals.profit*100),expected.accumulated_income,`${to}/${scope}/period profit`);assert.equal(Math.round(report.totals.position_profit*100),expected.accumulated_income,`${to}/${scope}/adjusted net assets`);
 results.push({to,scope,assets:expected.assets/100,liabilities:expected.liabilities/100,profit:expected.accumulated_income/100});
}
const periods=[];
const accountSum=(book,codes)=>[...book.accounts].filter(([key])=>codes.includes(key.split('|')[0])).reduce((sum,[,value])=>sum+value,0);
for(const [from,to] of [['2026-08-01','2026-08-31'],['2026-09-01','2026-09-30'],['2026-10-01','2026-10-31'],['2026-11-01',today]])for(const scope of ['all','lpg','stove','logistics']){
 const before=new Date(from+'T00:00:00Z');before.setUTCDate(before.getUTCDate()-1);
 const opening=calculateFinancialSources(m.events,before.toISOString().slice(0,10),scope),closing=calculateFinancialSources(m.events,to,scope);
 const report=await checked(c.rpc('get_finance_analysis',{p_filters:{business_id:m.tenant,from,to,category:scope,grain:'month'}}));
 const delta=codes=>accountSum(closing,codes)-accountSum(opening,codes);
 for(const key of ['revenue','expenses','withdrawals'])assert.equal(Math.round(report.totals[key]*100),closing[key]-opening[key],`${from}/${scope}/period ${key}`);
 assert.equal(Math.round(report.totals.profit*100),closing.accumulated_income-opening.accumulated_income);
 for(const [key,value] of Object.entries({stock_change:delta(['inventory']),receivable_change:delta(['receivable','receivable_supplier']),payable_change:-delta(['payable']),loan_movement:-delta(['loan']),wallet_movement:delta(['cash'])}))assert.equal(Math.round(report.period_values[key]*100),value||0,`${from}/${scope}/${key}`);
 const allocation=e=>scope==='all'?1:(e.allocations?.[scope]??0)/100;
 const equipment=m.events.filter(e=>e.date>=from&&e.date<=to&&(e.kind==='asset'&&e.funding!=='opening'||e.kind==='improvement')).reduce((sum,e)=>sum+e.amount*allocation(e),0);
 assert.equal(Math.round(report.period_values.equipment_acquisitions*100),Math.round(equipment*100),`${from}/${scope}/equipment acquisitions`);
 const capital=m.events.filter(e=>e.date>=from&&e.date<=to&&e.kind==='funding').reduce((sum,e)=>sum+e.amount*allocation(e),0);assert.equal(Math.round(report.totals.contributions*100),Math.round(capital*100),`${from}/${scope}/period capital`);
 const stock=m.events.filter(e=>e.kind==='purchase'&&e.date>=from&&e.date<=to&&(scope==='all'||e.business===scope)).reduce((sum,e)=>sum+e.quantity*(e.unit-e.rate)+(scope==='all'?0:e.transport??0),0);assert.equal(Math.round(report.period_values.stock_acquisitions*100),Math.round(stock*100),`${from}/${scope}/period acquisition cost`);
 periods.push({from,to,scope,profit:(closing.accumulated_income-opening.accumulated_income)/100});
}
const wallets=await checked(c.from('wallets').select('wallet_id,balance,business_balances'));for(const w of wallets){let total=0;for(const b of['lpg','stove','logistics']){const expected=calculateFinancialSources(m.events,today,b).accounts.get('cash|'+w.wallet_id)??0;assert.equal(Math.round(w.business_balances[b]*100),expected,'Independent business wallet');total+=expected;}assert.equal(Math.round(w.balance*100),total);}
writeFileSync(folder+'/verification.json',JSON.stringify({tenant:m.tenant,sourceEvents:m.events.length,results,periods},null,2));console.log('PASS 16 independent organization/business positions, 16 monthly period reports and every period activity field, original source inputs, FIFO, eliminations and exact wallet portions');
await c.auth.signOut({scope:'local'});
