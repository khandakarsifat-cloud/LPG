// Retained, explicitly named development business. Normal Auth/PostgREST only.
// Credentials are kept in ignored .env.fifo-test; no customer business is reused.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {existsSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {createClient} from '@supabase/supabase-js';
import {independentlyCalculate} from './fifo-independent.mjs';

assert(process.argv.includes('--vps'),'Explicit --vps required');
const config=parseEnv(readFileSync('deploy/.env.frontend','utf8'));
const api='https://api.lpg.144.79.249.4.sslip.io';assert.equal(config.VITE_SUPABASE_URL,api);
const folder='.temp/fifo-business';mkdirSync(folder,{recursive:true});
const manifestPath=folder+'/manifest.json';
const manifest=existsSync(manifestPath)?JSON.parse(readFileSync(manifestPath,'utf8')):{steps:{},spec:{events:[],rates:{},commissionGroups:[]}};
const spec=manifest.spec;const persist=()=>writeFileSync(manifestPath,JSON.stringify(manifest,null,2));
const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date());
const months=['2026-08','2026-09','2026-10'];assert(today>='2026-11-01','Lab requires the completed historical periods');
const start='2026-08-01';
const c=createClient(api,config.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const checked=async p=>{const {data,error}=await p;if(error)throw Error(`${error.code??'API'}: ${error.message}`);return data;};
let credentials;
if(existsSync('.env.fifo-test')){
 credentials=parseEnv(readFileSync('.env.fifo-test','utf8'));
 await checked(c.auth.signInWithPassword({email:credentials.LPG_TEST_EMAIL,password:credentials.LPG_TEST_PASSWORD}));
}else{
 assert(process.argv.includes('--create'),'Use --create once to create the retained isolated account');
 credentials={LPG_TEST_EMAIL:`lpg-fifo-20261101-${randomUUID().slice(0,8)}@example.invalid`,LPG_TEST_PASSWORD:randomUUID()+'Aa1!'};
 const auth=await checked(c.auth.signUp({email:credentials.LPG_TEST_EMAIL,password:credentials.LPG_TEST_PASSWORD}));assert(auth.session&&auth.user);
 manifest.user=auth.user.id;
 writeFileSync('.env.fifo-test',Object.entries(credentials).map(([k,v])=>`${k}=${v}`).join('\n')+'\n',{mode:0o600});persist();
}
async function rpc(label,name,args={}){
 if(manifest.steps[label]?.done)return manifest.steps[label].result;
 const saved=manifest.steps[label]??{request:randomUUID()};manifest.steps[label]=saved;persist();
 if(args.p_request_id===true)args={...args,p_request_id:saved.request};
 if(name==='create_purchase')args={...args,p_payload:{...args.p_payload,request_id:saved.request}};
 const result=await checked(c.rpc(name,args));saved.done=true;saved.result=result;persist();return result;
}
function event(label,body){if(spec.events.some(e=>e.label===label))return;spec.events.push({label,order:spec.events.length,...body});persist();}
async function operation(label,body){return rpc(label,'accounting_operation',{p_payload:body,p_request_id:true});}
async function payment(label,name,body){return rpc(label,name,{p_payload:body,p_request_id:true});}
const business=await rpc('setup','setup_business',{p_business_name:'LPG FIFO Development Lab 2026-11-01',p_owner_name:'FIFO development operator'});
manifest.tenant=business.tenant_id;persist();
const profile=await checked(c.from('user_profiles').select('tenant_id,is_active,tenants(business_name)').eq('user_id',(await c.auth.getUser()).data.user.id).single());
assert.equal(profile.tenant_id,manifest.tenant);assert(profile.is_active);assert.equal(profile.tenants.business_name,'LPG FIFO Development Lab 2026-11-01');
const tenant=manifest.tenant;
async function seed(){
 await rpc('profile','save_business_profile',{p_name:'LPG FIFO Development Lab 2026-11-01'});
 const wallets=await checked(c.rpc('get_payment_wallets'));const cash=wallets.find(w=>w.type==='cash').wallet_id;
 const bankResult=await rpc('bank','save_finance_wallet',{p_payload:{name:'DBBL Lab operating account',kind:'bank',details:'Retained isolated development fixture',is_active:true}});
 const bank=typeof bankResult==='string'?bankResult:bankResult.wallet_id;assert(bank);manifest.cash=cash;manifest.bank=bank;persist();
 for(const [wallet,amount,label] of [[cash,1000000,'cash'],[bank,750000,'bank']]){
  await operation('opening-'+label,{action:'opening_cash',wallet_id:wallet,amount,date:start,description:'Verified initial test-business funds'});event('opening-'+label,{kind:'funding',wallet,amount,date:start});
 }
 const opening=await operation('opening-liability',{action:'opening_entry',account:'operating_payable',amount:50000,date:start,description:'Opening unpaid shop rent and utilities'});manifest.openingObligation=opening.id;
 event('opening-liability',{kind:'openingLiability',amount:50000,date:start});
 const equipment=await operation('equipment',{action:'asset_register',name:'Shop scales, cages and office equipment',kind:'equipment',funding:'opening',amount:80000,date:start,description:'Verified shop equipment acquisition cost'});manifest.equipment=equipment.id;
 event('equipment',{kind:'asset',asset:'equipment',funding:'opening',amount:80000,date:start});
 const loan=await operation('loan',{action:'loan_create',lender:'Development cooperative lender',wallet_id:bank,amount:200000,date:'2026-08-06',description:'Working-capital principal received'});manifest.loan=loan.id;
 event('loan',{kind:'loan',wallet:bank,amount:200000,date:'2026-08-06'});
 const employees=[];
 for(const [index,name,role,salary] of [[0,'Rahim Lab','Driver',14000],[1,'Karim Lab','Helper',9000],[2,'Nadia Lab','Manager',16000]]){
  const employee=await rpc('employee-'+index,'save_employee',{p_payload:{name,employee_type_name:role,business_unit:role==='Manager'?'gas_business':'truck_business',phones:[{phone:`0179900000${index+1}`,is_primary:true}],terms:{effective_from:start,monthly_salary:salary,is_active:true}},p_request_id:true});
  employees.push(employee.employee_id);
  for(const month of [...months,today.slice(0,7)])event(`salary-${index}-${month}`,{kind:'salary',amount:salary,date:month+'-01',employee:employee.employee_id});
  for(const month of months){const amount=Math.floor(salary*.6),date=month+'-25';await payment(`salary-pay-${index}-${month}`,'employee_payment_operation',{action:'pay',items:[{employee_id:employee.employee_id,period:month+'-01',kind:'salary',payment_date:date,description:'Partial monthly salary paid',payments:[{wallet_id:cash,amount}]}]});event(`salary-pay-${index}-${month}`,{kind:'employeePayment',wallet:cash,amount,date});}
 }
 manifest.employees=employees;
 const advance=2000;await payment('salary-advance','employee_payment_operation',{action:'pay',items:[{employee_id:employees[0],period:'2026-10-01',kind:'salary',payment_date:'2026-09-20',description:'Advance against October salary',payments:[{wallet_id:bank,amount:advance}]}]});event('salary-advance',{kind:'employeePayment',wallet:bank,amount:advance,date:'2026-09-20'});
 await payment('bonus','employee_payment_operation',{action:'pay',items:[{employee_id:employees[2],kind:'bonus',bonus_name:'Festival bonus',payment_date:'2026-10-15',description:'Retained festival-bonus fixture',payments:[{wallet_id:cash,amount:1500}]}]});event('bonus-earned',{kind:'bonus',amount:1500,date:'2026-10-15'});event('bonus-paid',{kind:'employeePayment',wallet:cash,amount:1500,date:'2026-10-15'});
 const truck=await rpc('truck','save_vehicle',{p_payload:{name:'Lab delivery truck',serial_no:'LAB-DHK-1101',capacity:300,driver_employee_id:employees[0],helper_employee_id:employees[1],book_value:800000,funding:'opening',acquired_on:start},p_request_id:true});manifest.truck=truck.vehicle_id;
 event('truck',{kind:'asset',asset:'vehicles',funding:'opening',amount:800000,date:start});
 const standby=await rpc('standby-truck','save_vehicle',{p_payload:{name:'Lab reserve pickup',serial_no:'LAB-DHK-1102',capacity:80,book_value:200000,funding:'opening',acquired_on:start},p_request_id:true});manifest.standby=standby.vehicle_id;event('standby-truck',{kind:'asset',asset:'vehicles',funding:'opening',amount:200000,date:start});
 const products=[];const brands=[];
 for(const [bi,name] of ['Lab Bashundhara','Lab Omera'].entries()){
  const brandResult=await rpc('brand-'+bi,'create_lpg_brand',{p_brand_name:name,p_description:'Isolated FIFO development supplier'});const brand=brandResult.brand_id;
  const plant=(await rpc('plant-'+bi,'create_gas_plant',{p_plant_name:name+' Dhaka plant',p_brand_id:brand,p_location:'Savar, Dhaka'})).plant_id;
  brands.push({id:brand,plant,index:bi,name});
  for(const kg of [12,35])for(const mouth of ['22mm','20mm']){
   const key=`lpg-${bi}-${kg}-${mouth}`;let row=manifest.steps[key]?.result;
   if(!row){row=await checked(c.from('items').insert({tenant_id:tenant,brand_id:brand,size_kg:kg,mouth_size:mouth}).select('item_id').single());manifest.steps[key]={done:true,result:row};persist();}
   const product={id:row.item_id,brand,kg,mouth,category:'lpg',shell:kg===12?1500:3500};products.push(product);
   await rpc('initial-'+key,'adjust_inventory',{p_payload:{item_id:product.id,kind:'opening',filled_quantity:30,empty_quantity:50,filled_unit_cost:product.shell+(kg===12?1100:3000),empty_unit_cost:product.shell,date:start,reason:'Verified opening filled cylinders and spare shells'},p_request_id:true});
   event('initial-filled-'+key,{kind:'openingStock',item:product.id,part:'filled',quantity:30,unit:product.shell+(kg===12?1100:3000),shell:product.shell,date:start});event('initial-empty-'+key,{kind:'openingStock',item:product.id,part:'empty',quantity:50,unit:product.shell,date:start});
  }
 }
 const types=await checked(c.rpc('get_stove_product_types'));
 for(let index=0;index<4;index++){
  const type=types.find(t=>t.name===['Single Stove','Double Stove','Regulator','Pipe'][index])??types[index];
  const row=await rpc('stove-'+index,'save_stove_product',{p_payload:{name:['Lab single-burner stove','Lab double-burner stove','Lab pressure regulator','Lab safety hose'][index],type_id:type.type_id},p_request_id:true});
  const product={id:row.item_id,category:'stove',index,shell:0};products.push(product);
  await rpc('initial-stove-'+index,'adjust_inventory',{p_payload:{item_id:product.id,kind:'opening',filled_quantity:15,empty_quantity:0,filled_unit_cost:[1200,2200,300,150][index],date:start,reason:'Verified initial stove-business supplies'},p_request_id:true});event('initial-stove-'+index,{kind:'openingStock',item:product.id,part:'filled',quantity:15,unit:[1200,2200,300,150][index],date:start});
 }
 manifest.products=products;manifest.brands=brands;persist();
 const customers=[];
 for(let i=0;i<24;i++){
  const label='customer-'+i;let customer=manifest.steps[label]?.result;
  if(!customer){customer=await checked(c.from('customers').insert({tenant_id:tenant,name:`Lab customer ${String(i+1).padStart(2,'0')}`,shop_name:i%2?'Lab retail family':`Lab wholesale shop ${i+1}`,phone:'01899'+String(i+1).padStart(6,'0'),tier:i%2?'retail':'wholesale',address:['Savar','Ashulia','Mirpur','Tongi'][i%4]}).select('customer_id,name,phone,tier').single());manifest.steps[label]={done:true,result:customer};persist();}customers.push(customer);
 }
 manifest.customers=customers;
 // Supplemental opening receivable remains separate from new invoices.
 await operation('opening-receivable',{action:'opening_entry',account:'customer_receivable',entity_id:customers[23].customer_id,amount:7000,date:start,description:'Verified carried customer balance'});event('opening-receivable',{kind:'openingReceivable',customer:customers[23].customer_id,amount:7000,date:start});
 let firstReturn;
 for(const [mi,month] of months.entries()){
  console.log(`Seeding ${month}: purchase batches, commissions, invoices, settlements and costs`);
  for(const product of products){
   if(product.category==='lpg'&&(mi===2||mi===1&&product.mouth==='22mm')){
    const rate=product.kg*(mi===2?6:5),key=`${month}:${product.id}`;const current=await checked(c.rpc('get_monthly_commissions',{p_item_id:product.id,p_month:month+'-01'}));
    await rpc('rate-'+key,'set_monthly_commission',{p_payload:{item_id:product.id,month:month+'-01',package_rate:rate,refill_rate:rate,expected_revision:current.current?.revision??0,reason:'Documented monthly supplier rate for development lab'},p_request_id:true});spec.rates[key]=rate;persist();
   }
   const base=product.category==='lpg'?(product.kg===12?[1400,1550,1300][mi]:[3900,4200,3700][mi]):[1800,3200,500,300][product.index]+mi*50;
   for(const tier of ['retail','wholesale']){
    const current=await checked(c.rpc('get_product_inventory',{p_item_id:product.id}));const expected={refill:current.prices.find(p=>p.customer_tier===tier&&p.price_type==='refill')?.effective_from??null,package:current.prices.find(p=>p.customer_tier===tier&&p.price_type==='package')?.effective_from??null};
    const price=base-(tier==='wholesale'?50:0);
    if(product.category==='lpg')await rpc(`prices-${month}-${product.id}-${tier}`,'save_product_prices',{p_item_id:product.id,p_customer_tier:tier,p_prices:{refill:{price,mrp:null},package:{price:price+product.shell+100,mrp:null}},p_expected:expected});
    else await rpc(`prices-${month}-${product.id}-${tier}`,'save_product_prices',{p_item_id:product.id,p_customer_tier:tier,p_prices:{refill:{price:0,mrp:null},package:{price,mrp:null}},p_expected:expected});
   }
  }
  for(const brand of brands){
   const groupItems=products.filter(p=>p.brand===brand.id);
   const cg={month,brand:brand.id,items:groupItems.map(p=>({id:p.id,kg:p.kg,quantity:28})),deductions:[]};
   if(!spec.commissionGroups.some(g=>g.month===month&&g.brand===brand.id)){spec.commissionGroups.push(cg);persist();}
   for(const [batch,day] of [[0,'04'],[1,'24']]){
    const previous=mi?months[mi-1]:null;const previousGroup=previous&&spec.commissionGroups.find(g=>g.month===previous&&g.brand===brand.id);
    const fullPrevious=previousGroup?previousGroup.items.reduce((sum,p)=>sum+p.quantity*p.kg*(mi===1?4:5),0):0;
    const deduction=Math.round(fullPrevious*(batch===0?.5:.25)*100)/100;
    const lines=groupItems.flatMap(p=>{const gas=p.kg===12?[1000,1250,900][mi]:[2800,3400,2500][mi];return batch===0?[{item:p.id,type:'refill',quantity:16,unit:gas,shell:p.shell},{item:p.id,type:'package',quantity:8,unit:gas+p.shell,shell:p.shell}]:[{item:p.id,type:'package',quantity:4,unit:gas+p.shell,shell:p.shell}];});
    const label=`purchase-${month}-${brand.index}-${batch}`,date=month+'-'+day;
    const p=await rpc(label,'create_purchase',{p_payload:{plant_id:brand.plant,vehicle_id:manifest.truck,commission:deduction,transport_cost:0,labour_cost:0,notes:'Retained multi-month FIFO/commission source fixture',items:lines.map(l=>({item_id:l.item,type:l.type,quantity:l.quantity,unit_price:l.unit,empty_dispatched:l.type==='refill'?l.quantity:0,...(l.type==='package'?{shell_unit_cost:l.shell}:{})}))}});
    await rpc(label+'-dispatch','dispatch_purchase',{p_purchase_id:p.purchase_id,p_revision:1,p_dispatched_on:date});
    await rpc(label+'-receive','receive_purchase',{p_purchase_id:p.purchase_id,p_revision:2,p_received_on:date});
    event(label,{kind:'purchase',id:p.purchase_id,date,lines,deduction});
    if(previousGroup&&!previousGroup.deductions.some(d=>d.id===p.purchase_id)){previousGroup.deductions.push({id:p.purchase_id,amount:deduction});persist();}
    const total=lines.reduce((sum,l)=>sum+l.quantity*l.unit,0)-deduction;
    for(const [wi,wallet] of [cash,bank].entries()){
     const amount=Math.round(total*(batch===0?(wi===0?.3:.2):(wi===0?.7:.3))*100)/100;
     await rpc(label+'-pay-'+wi,'record_purchase_payment',{p_purchase_id:p.purchase_id,p_payments:[{wallet_id:wallet,amount,reference:'Retained supplier settlement'}],p_request_id:true});event(label+'-pay-'+wi,{kind:'purchasePayment',purchase:p.purchase_id,wallet,amount,date:today});
    }
   }
  }
  const stoveLines=products.filter(p=>p.category==='stove').map(p=>({item:p.id,type:'package',quantity:25,unit:[1300,2400,320,160][p.index]+mi*100,shell:0}));
  const stovePurchase=await rpc('stove-purchase-'+month,'create_purchase',{p_payload:{business_category:'stove',supplier_name:'Lab stove manufacturer',items:stoveLines.map(l=>({item_id:l.item,type:'package',quantity:l.quantity,unit_price:l.unit}))}});
  await rpc('stove-receive-'+month,'receive_purchase',{p_purchase_id:stovePurchase.purchase_id,p_revision:1,p_received_on:month+'-05'});event('stove-purchase-'+month,{kind:'purchase',id:stovePurchase.purchase_id,date:month+'-05',lines:stoveLines});
  const stovePay=stoveLines.reduce((sum,l)=>sum+l.quantity*l.unit,0)*.5;
  await rpc('stove-pay-'+month,'record_purchase_payment',{p_purchase_id:stovePurchase.purchase_id,p_payments:[{wallet_id:bank,amount:stovePay}],p_request_id:true});event('stove-pay-'+month,{kind:'purchasePayment',wallet:bank,amount:stovePay,date:today});
  for(const [pi,product] of products.entries())for(const [di,day] of ['08','10','12','14','16','18','20','22'].entries()){
   const label=`sale-${month}-${pi}-${di}`,customer=customers[(pi*2+di)%customers.length],tier=customer.tier;
   const gas=product.category==='lpg'?(product.kg===12?[1400,1550,1300][mi]:[3900,4200,3700][mi]):[1800,3200,500,300][product.index]+mi*50;
   const type=product.category==='stove'||di%3===0?'package':'refill',quantity=type==='refill'?2:1,unit=gas-(tier==='wholesale'?50:0)+(product.category==='lpg'&&type==='package'?product.shell+100:0),discount=di%4===0?5:0;
   const items=[{item_id:product.id,type,quantity,unit_price:unit},...(type==='refill'?[{item_id:product.id,type:'empty_return',quantity,unit_price:0}]:[])];
   const returned=type==='refill'?(di%2?1:2):0;
   const sale=await rpc(label,'create_pos_sale',{p_customer_phone:customer.phone,p_customer_name:customer.name,p_customer_shop_name:null,p_customer_address:null,p_customer_tier:tier,p_discount_amount:discount,p_exchange_fee:0,p_notes:'Retained original FIFO lab invoice',p_items:items,p_customer_id:customer.customer_id,p_request_id:true,p_payments:[],p_bottles:type==='refill'?{lines:[{received_item_id:product.id,quantity:returned}]}:null,p_sold_on:month+'-'+day});
   const total=quantity*unit-discount;
   event(label,{kind:'sale',id:sale.sale_id,customer:customer.customer_id,date:month+'-'+day,amount:total,lines:[{item:product.id,type,quantity}],returned:returned?[{item:product.id,quantity:returned}]:[]});
   if(!firstReturn&&product.category==='stove')firstReturn={sale:sale.sale_id,customer:customer.customer_id,amount:total};
   if(di%3!==1){const amount=Math.round(total*(di%3===0?1:.4)*100)/100;const wallet=di%2?cash:bank;await rpc(label+'-collection','collect_sale_payment',{p_sale_id:sale.sale_id,p_payments:[{wallet_id:wallet,amount,reference:'Retained customer settlement'}],p_request_id:true});event(label+'-collection',{kind:'collection',sale:sale.sale_id,customer:customer.customer_id,wallet,amount,date:today});}
   if(type==='refill'&&returned===1&&di===1){const other=products.find(p=>p.category==='lpg'&&p.brand!==product.brand&&p.kg===product.kg&&p.mouth===product.mouth);await rpc(label+'-bottles','collect_sale_bottles',{p_sale_id:sale.sale_id,p_payload:{lines:[{received_item_id:other.id,quantity:1,acknowledged:true}],note:'Later acknowledged cross-brand shell exchange'},p_request_id:true});event(label+'-bottles',{kind:'bottleCollection',sale:sale.sale_id,customer:customer.customer_id,item:other.id,quantity:1,amount:product.shell,date:today});}
  }
  for(const product of [products[0],products[8]]){await rpc(`loss-${month}-${product.id}`,'adjust_inventory',{p_payload:{item_id:product.id,kind:'damaged',filled_quantity:-1,empty_quantity:0,date:month+'-26',reason:'Verified damaged unit removed from saleable stock'},p_request_id:true});event(`loss-${month}-${product.id}`,{kind:'loss',item:product.id,part:'filled',quantity:1,date:month+'-26'});}
  if(mi){await operation('repayment-'+month,{action:'loan_repay',loan_id:loan.id,wallet_id:bank,amount:50000,date:month+'-27',description:'Working-capital principal repayment'});event('repayment-'+month,{kind:'repayment',wallet:bank,amount:50000,date:month+'-27'});}
  await operation('depreciation-'+month,{action:'asset_depreciate',asset_id:equipment.id,amount:2000,date:month+'-28',description:'Explicit monthly equipment depreciation'});event('depreciation-'+month,{kind:'depreciation',asset:'equipment',amount:2000,date:month+'-28'});
  const categories=(await checked(c.rpc('get_financial_catalog'))).types.filter(x=>x.origin==='custom');const cost=categories.find(x=>x.account==='operating_expense');const interest=categories.find(x=>x.account==='interest_expense');const withdrawal=categories.find(x=>x.account==='withdrawals');assert(cost&&interest&&withdrawal);
  for(const [label,category,amount] of [['rent',cost,12000],['interest',interest,3000],['withdrawal',withdrawal,15000]]){await payment(`${label}-${month}`,'record_financial_entry',{type_id:category.type_id,expected_revision:category.revision,wallet_id:cash,amount,date:month+'-28',description:'Retained lab '+label});event(`${label}-${month}`,{kind:'spending',wallet:cash,amount,withdrawal:category.account==='withdrawals',date:month+'-28'});}
  if(mi){await operation('capital-'+month,{action:'capital',wallet_id:bank,amount:25000,date:month+'-02',description:'Additional owner working-capital investment'});event('capital-'+month,{kind:'funding',wallet:bank,amount:25000,date:month+'-02'});}
  persist();
 }
 // Confirm one historical product after partial deductions. All other inferred
 // rates remain explicitly provisional; the model independently redistributes.
 const confirmed=products[0],month=months[0];const current=await checked(c.rpc('get_monthly_commissions',{p_item_id:confirmed.id,p_month:month+'-01'}));
 await rpc('historical-manual-confirmation','set_monthly_commission',{p_payload:{item_id:confirmed.id,month:month+'-01',package_rate:50,refill_rate:50,expected_revision:current.current.revision,reason:'Supplier confirms historical 12 kg entitlement after partial deductions'},p_request_id:true});spec.rates[`${month}:${confirmed.id}`]=50;
 manifest.firstReturn=firstReturn;persist();
 assert(firstReturn);
 await rpc('sale-return','reverse_sale',{p_sale_id:firstReturn.sale,p_reason:'Unused stove returned; original FIFO batch restored',p_confirmation:'CANCEL',p_request_id:true});event('sale-return',{kind:'reversal',sale:firstReturn.sale,date:today});
 for(const [wi,wallet] of [cash,bank].entries()){const amount=Math.round(firstReturn.amount*(wi===0?.6:.4)*100)/100;await rpc('sale-refund-'+wi,'refund_sale',{p_sale_id:firstReturn.sale,p_payments:[{wallet_id:wallet,amount}],p_request_id:true});event('sale-refund-'+wi,{kind:'refund',customer:firstReturn.customer,wallet,amount,date:today});}
 await payment('transfer','move_wallet_money',{action:'transfer',wallet_id:bank,destination_id:cash,amount:10000,reason:'Retained lab cash replenishment'});event('transfer',{kind:'transfer',wallet:bank,destination:cash,amount:10000,date:today});
 await operation('settle-opening',{action:'settle_obligation',obligation_id:manifest.openingObligation,wallet_id:cash,amount:20000,date:today,description:'Partial settlement of initial unpaid shop costs'});event('settle-opening',{kind:'expensePayment',wallet:cash,amount:20000,date:today});
 manifest.seedComplete=true;persist();
}

async function extend(){
 const {cash,bank,truck,standby,employees}=manifest;
 const transit=await rpc('lab-custom-transit','create_custom_transit',{p_payload:{vehicle_id:truck,fee:5000,client_name:'Lab third-party delivery client',destination:'Mirpur, Dhaka'},p_request_id:true});manifest.customTransit=transit.transit_id;persist();
 event('lab-custom-transit',{kind:'transitRevenue',amount:5000,date:today});
 await rpc('lab-transit-costs','save_transit_costs',{p_transit_id:transit.transit_id,p_costs:{driver_cost:200,helper_cost:100,oil_cost:600,others_cost:0,additional_costs:[]},p_revision:1});event('lab-transit-crew',{kind:'crewCost',amount:300,date:today});event('lab-transit-oil',{kind:'transitCost',amount:600,date:today});
 for(const [index,wallet,amount] of [[0,cash,3000],[1,bank,1500],[2,cash,500]]){await payment('lab-transit-collection-'+index,'record_operating_payment',{transit_id:transit.transit_id,kind:'client_receipt',payment_date:today,payments:[{wallet_id:wallet,amount}]});event('lab-transit-collection-'+index,{kind:'transitCollection',wallet,amount,date:today});}
 await payment('lab-transit-expense','record_operating_payment',{transit_id:transit.transit_id,kind:'expense',payment_date:today,payments:[{wallet_id:cash,amount:300},{wallet_id:bank,amount:300}]});event('lab-transit-expense-cash',{kind:'transitPayment',wallet:cash,amount:300,date:today});event('lab-transit-expense-bank',{kind:'transitPayment',wallet:bank,amount:300,date:today});
 for(const [index,role,amount] of [[0,'driver',200],[1,'helper',100]]){await payment('lab-trip-pay-'+role,'employee_payment_operation',{action:'pay',items:[{employee_id:employees[index],kind:'trips',trip_count:1,transit_id:transit.transit_id,trip_role:role,payment_date:today,payments:[{wallet_id:cash,amount}]}]});event('lab-trip-pay-'+role,{kind:'employeePayment',wallet:cash,amount,date:today});}
 let detail=await checked(c.rpc('get_transit',{p_transit_id:transit.transit_id}));await rpc('lab-transit-return','transition_transit',{p_transit_id:transit.transit_id,p_action:'return',p_revision:detail.revision});detail=await checked(c.rpc('get_transit',{p_transit_id:transit.transit_id}));await rpc('lab-transit-complete','transition_transit',{p_transit_id:transit.transit_id,p_action:'complete',p_revision:detail.revision});
 const categories=await checked(c.rpc('get_vehicle_expense_categories'));const category=categories.find(x=>x.name==='Engine Oil')??categories.find(x=>x.is_active);assert(category);
 const service=await rpc('lab-service','save_service_trip',{p_payload:{vehicle_id:truck,title:'Lab delivery-truck service',service_date:today,expenses:[{category_id:category.category_id,amount:1000,description:'Verified maintenance invoice'}]},p_request_id:true});manifest.service=service.service_trip_id;persist();event('lab-service',{kind:'transitCost',amount:1000,date:today});
 // Deliberate advance, then source-backed return before finalization.
 await payment('lab-service-payment','record_operating_payment',{service_trip_id:service.service_trip_id,kind:'expense',payment_date:today,payments:[{wallet_id:bank,amount:1100}]});event('lab-service-payment',{kind:'transitPayment',wallet:bank,amount:1100,date:today});
 const payments=await checked(c.rpc('get_operating_payments',{p_transit_id:null,p_service_trip_id:service.service_trip_id,p_offset:0,p_limit:8}));const original=payments.entries.find(p=>p.kind==='expense');assert(original);
 await payment('lab-service-return','record_operating_payment',{service_trip_id:service.service_trip_id,kind:'expense_return',return_of:original.payment_id,payment_date:today,payments:[{wallet_id:bank,amount:100}]});event('lab-service-return',{kind:'transitPayment',wallet:bank,amount:-100,date:today});
 const serviceDetail=await checked(c.rpc('get_service_trip',{p_service_trip_id:service.service_trip_id}));await rpc('lab-service-complete','finalize_service_trip',{p_service_trip_id:service.service_trip_id,p_revision:serviceDetail.revision,p_request_id:true});
 const asset=(await checked(c.rpc('get_vehicle',{p_vehicle_id:standby}))).asset.asset_id;
 await operation('lab-vehicle-depreciation',{action:'asset_depreciate',asset_id:asset,amount:10000,date:today,description:'Recorded reserve-pickup depreciation'});event('lab-vehicle-depreciation',{kind:'depreciation',asset:'vehicles',amount:10000,date:today});
 await operation('lab-vehicle-disposal',{action:'asset_dispose',asset_id:asset,method:'sold',proceeds:195000,expense:1000,wallet_id:cash,date:today,description:'Reserve pickup sold with source-backed proceeds and disposal expense'});event('lab-vehicle-disposal',{kind:'disposal',asset:'vehicles',book:190000,proceeds:195000,expense:1000,wallet:cash,date:today});
 const obligation=await operation('lab-backdated-obligation',{action:'expense_accrue',amount:6000,date:'2026-10-15',description:'Backdated October shop repair invoice'});event('lab-backdated-obligation',{kind:'expenseAccrual',amount:6000,date:'2026-10-15'});
 await operation('lab-obligation-payment',{action:'settle_obligation',obligation_id:obligation.id,wallet_id:bank,amount:2000,date:today,description:'Partial payment of shop repair invoice'});event('lab-obligation-payment',{kind:'expensePayment',liability:'other',wallet:bank,amount:2000,date:today});
 const product=manifest.products.find(p=>p.category==='stove');const cancelled=await rpc('lab-cancel-purchase','create_purchase',{p_payload:{business_category:'stove',supplier_name:'Lab returnable stove order',items:[{item_id:product.id,type:'package',quantity:5,unit_price:1000}]}});
 await rpc('lab-cancel-pay','record_purchase_payment',{p_purchase_id:cancelled.purchase_id,p_payments:[{wallet_id:cash,amount:1500},{wallet_id:bank,amount:500}],p_request_id:true});event('lab-cancel-pay-cash',{kind:'purchasePayment',wallet:cash,amount:1500,date:today});event('lab-cancel-pay-bank',{kind:'purchasePayment',wallet:bank,amount:500,date:today});
 await rpc('lab-cancel-receive','receive_purchase',{p_purchase_id:cancelled.purchase_id,p_revision:2});event('lab-cancel-receive',{kind:'purchase',id:cancelled.purchase_id,date:today,lines:[{item:product.id,type:'package',quantity:5,unit:1000}]});
 const purchase=(await checked(c.rpc('get_purchases_by_ids',{p_ids:[cancelled.purchase_id]})))[0];await rpc('lab-cancel-final','initiate_purchase_cancellation',{p_purchase_id:cancelled.purchase_id,p_revision:purchase.revision,p_confirmation:'CANCEL',p_request_id:true});event('lab-cancel-final',{kind:'purchaseCancel',purchase:cancelled.purchase_id,amount:5000,date:today});
 const settlement=await checked(c.rpc('get_purchase_settlement',{p_purchase_id:cancelled.purchase_id}));assert.equal(settlement.refund_due+settlement.refunded,2000);
 for(const obligation of settlement.obligations){const amount=obligation.amount;await rpc('lab-purchase-refund-'+obligation.obligation_id,'refund_purchase',{p_purchase_id:cancelled.purchase_id,p_obligation_id:obligation.obligation_id,p_payments:[{wallet_id:bank,amount}],p_request_id:true});event('lab-purchase-refund-'+obligation.obligation_id,{kind:'purchasePayment',wallet:bank,amount:-amount,date:today});}
 manifest.extrasComplete=true;persist();console.log('PASS retained logistics, split crew/operating settlements, service advance/return, depreciation/disposal, backdated obligation and purchase cancellation/refund operations');
}

async function prepareTransit(){
 const item=manifest.products[0];const brand=manifest.brands.find(b=>b.id===item.brand);
 const p=await rpc('lab-pending-purchase','create_purchase',{p_payload:{plant_id:brand.plant,vehicle_id:manifest.truck,commission:75,transport_cost:1000,labour_cost:0,notes:'Retained in-transit stock and pending commission settlement',items:[{item_id:item.id,type:'refill',quantity:2,unit_price:1400,empty_dispatched:2},{item_id:item.id,type:'package',quantity:1,unit_price:2900,empty_dispatched:0,shell_unit_cost:1500}]}});
 await rpc('lab-pending-dispatch','dispatch_purchase',{p_purchase_id:p.purchase_id,p_revision:1});event('lab-pending-dispatch',{kind:'transitPurchase',item:item.id,refills:2,amount:5700,deduction:75,date:today});
 await rpc('lab-pending-payment','record_purchase_payment',{p_purchase_id:p.purchase_id,p_payments:[{wallet_id:manifest.cash,amount:1000}],p_request_id:true});event('lab-pending-payment',{kind:'purchasePayment',wallet:manifest.cash,amount:1000,date:today});manifest.pendingPurchase=p.purchase_id;manifest.transitComplete=true;persist();
}

async function verify(){
 // A reviewed addendum contains original source inputs entered after the fixture,
 // never journal/report differences or balancing adjustments.
 const extraPath=folder+'/source-addendum.json';
 const extra=existsSync(extraPath)?JSON.parse(readFileSync(extraPath,'utf8')):{tenant,events:[]};assert.equal(extra.tenant,tenant);
 const spec={...manifest.spec,events:[...manifest.spec.events,...extra.events]};
 const labObligationPayment=spec.events.find(e=>e.label==='lab-obligation-payment');if(labObligationPayment)labObligationPayment.liability='other';
 const intervals=[['2026-08-01','2026-08-31'],['2026-09-01','2026-09-30'],['2026-10-01','2026-10-31'],['2026-08-15','2026-10-20'],['2026-01-01',today],[start,today]];
 const results=[];const priorDay=d=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()-1);return x.toISOString().slice(0,10);};
 for(const [from,to] of intervals){
  const startExpected=independentlyCalculate(spec,priorDay(from)),end=independentlyCalculate(spec,to);
  const t0=performance.now();const report=await checked(c.rpc('get_finance_analysis',{p_filters:{business_id:tenant,from,to,grain:'month'}}));const ms=Math.round(performance.now()-t0);
  for(const [side,expected] of [['opening',startExpected],['closing',end]]){
   for(const [key,value] of [['assets',expected.assets],['liabilities',expected.liabilities],['equity',expected.equity],['cash',expected.balances.cash],['capital',expected.balances.capital],['revenue',expected.balances.revenue],['expenses',expected.balances.expenses],['withdrawals',expected.balances.withdrawals],['accumulated_income',expected.profit]])assert.equal(Math.round(report[side][key]*100),value,`${from}..${to} ${side}.${key}`);
   const sum=code=>Math.round(report[side].accounts.filter(a=>a.account===code).reduce((n,a)=>n+a.amount,0)*100);
   for(const [code,value] of [['supplier_payable',expected.balances.supplierDebt],['employee_payable',expected.balances.employeeDebt],['operating_payable',expected.balances.operatingDebt],['other_liability',expected.balances.otherLiabilities],['commission_pending',expected.balances.pendingCommissions],['inventory_transit',expected.balances.transit]])assert.equal(sum(code),value,`${from}..${to} ${side}.${code}`);
   for(const [codes,value] of [[['inventory_lpg','inventory_stove'],expected.balances.inventory],[['bottle_receivable'],expected.balances.bottles],[['vehicles'],expected.balances.vehicles],[['equipment'],expected.balances.equipment],[['supplier_receivable'],expected.balances.supplierCredits],[['loan_payable'],expected.balances.loans],[['customer_receivable'],expected.balances.receivables]])assert.equal(codes.reduce((n,code)=>n+sum(code),0),value,`${from}..${to} ${side} ${codes}`);
  }
  assert.equal(Math.round(report.totals.profit*100),end.profit-startExpected.profit,'Independent period P/L');results.push({from,to,ms,expectedClosing:end.balances,assets:end.assets/100,liabilities:end.liabilities/100,equity:end.equity/100,profit:(end.profit-startExpected.profit)/100});
  for(const point of report.trend){
   const before=independentlyCalculate(spec,priorDay(point.period_start)),after=independentlyCalculate(spec,point.period_end);
   for(const [key,value] of [['assets',after.assets],['liabilities',after.liabilities],['net_worth',after.equity],['revenue',after.balances.revenue-before.balances.revenue],['expenses',after.balances.expenses-before.balances.expenses],['profit',after.profit-before.profit]])assert.equal(Math.round(point[key]*100),value,'Independent chart bucket '+point.period_start+' '+key);
  }
  console.log(`PASS independent operations: ${from}..${to}, profit Tk ${results.at(-1).profit}, report ${ms} ms`);
 }
 const end=independentlyCalculate(spec,today),wallets=await checked(c.from('wallets').select('wallet_id,balance'));
 for(const wallet of wallets)assert.equal(Math.round(wallet.balance*100),end.wallets[wallet.wallet_id]??0,'Independent current wallet balance');
 for(const product of manifest.products){const pool=(await checked(c.rpc('get_inventory_cost_history',{p_item_id:product.id}))).pool;for(const component of ['filled','empty']){const expected=end.inventoryByItem[`${product.id}:${component}`]??{quantity:0,value:0};assert.equal(pool[component+'_quantity'],expected.quantity,'Independent SKU quantity');assert.equal(Math.round(pool[component+'_value']*100),expected.value,'Independent SKU FIFO value');}}
 const bottleBySale=new Map();for(const e of spec.events){if(e.kind==='sale')bottleBySale.set(e.id,{customer:e.customer,quantity:e.lines.filter(l=>l.type==='refill').reduce((n,l)=>n+l.quantity,0)-(e.returned??[]).reduce((n,l)=>n+l.quantity,0)});else if(e.kind==='bottleCollection')bottleBySale.get(e.sale).quantity-=e.quantity;}
 const bottleByCustomer=new Map();for(const s of bottleBySale.values())bottleByCustomer.set(s.customer,(bottleByCustomer.get(s.customer)??0)+Math.max(0,s.quantity));
 for(const kind of ['all','payment','bottle','both','none']){
  const expected=mappedCustomers(kind);const rows=await checked(c.rpc('get_customer_directory',{p_filters:{dues:kind,sort:'name_asc'},p_offset:0,p_limit:100}));assert.equal(rows.total,expected.length,'Independent current dues-filter total '+kind);assert.deepEqual(rows.entries.map(e=>e.customer_id).sort(),expected.sort(),'Independent customer dues membership '+kind);
  for(const customer of rows.entries)assert.equal(Math.round(customer.total_due*100),Math.max(0,end.customers[customer.customer_id]??0),'Directory due matches independent customer ledger, including opening balances');
 }
 function mappedCustomers(kind){return manifest.customers.filter(customer=>{const payment=(end.customers[customer.customer_id]??0)>0,bottle=(bottleByCustomer.get(customer.customer_id)??0)>0;return kind==='all'||kind===(payment&&bottle?'both':payment?'payment':bottle?'bottle':'none');}).map(c=>c.customer_id);}
 const all=await checked(c.rpc('get_finance_analysis',{p_filters:{business_id:tenant,from:start,to:today,all_time:true,grain:'month'}}));assert.equal(Math.round(all.closing.assets*100),end.assets);assert.equal(Math.round(all.closing.accumulated_income*100),end.profit);
 const initial=independentlyCalculate({...spec,events:spec.events.filter(e=>e.date===start&&(['openingStock','openingReceivable','openingLiability'].includes(e.kind)||e.kind==='asset'&&e.funding==='opening'||e.kind==='funding'&&e.label.startsWith('opening-')))},start);
 for(const [key,value] of [['assets',initial.assets],['liabilities',initial.liabilities],['equity',initial.equity],['capital',initial.balances.capital],['cash',initial.balances.cash],['accumulated_income',0]])assert.equal(Math.round(all.opening[key]*100),value,'Independent original business opening '+key);
 writeFileSync(folder+'/independent-reconciliation.json',JSON.stringify({tenant,sourceEvents:spec.events.length,intervals:results,current:end},null,2));
 console.log(`PASS retained business ${tenant}: ${spec.events.length} original operation events, independent account components, current wallets and all-time analysis`);
}
try{
 if(process.argv.includes('--create')&&!manifest.seedComplete)await seed();
 assert(manifest.seedComplete,'Complete --create before verification');
 if(process.argv.includes('--extend')&&!manifest.extrasComplete)await extend();
 if(process.argv.includes('--extend')&&manifest.extrasComplete&&!manifest.transitComplete)await prepareTransit();
 await verify();
}catch(error){console.error(String(error.stack??error).replaceAll(credentials.LPG_TEST_PASSWORD,'[redacted]').replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g,'[redacted JWT]'));process.exitCode=1;}
finally{await c.auth.signOut({scope:'local'});}
