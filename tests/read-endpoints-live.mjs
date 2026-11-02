// Normal-permission, read-only contract sweep against the existing burner business.
import assert from 'node:assert/strict';
import {readFileSync,mkdirSync,writeFileSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {createClient} from '@supabase/supabase-js';
assert(process.argv.includes('--vps'),'Explicit --vps required');
const f=parseEnv(readFileSync('deploy/.env.frontend','utf8')),s={...parseEnv(readFileSync('.env.live-test','utf8')),...process.env};
const api='https://api.lpg.144.79.249.4.sslip.io';assert.equal(f.VITE_SUPABASE_URL,api);assert.equal(s.LPG_TEST_EMAIL,'sifatsiam244@gmail.com');
const c=createClient(api,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}}),results=[];
const checked=async p=>{const{data,error}=await p;if(error)throw Error(error.code+': '+error.message);return data;};
const rpc=async(name,args={})=>{const start=performance.now();try{const data=await checked(c.rpc(name,args));results.push({name,status:'pass',ms:Math.round(performance.now()-start)});return data;}catch(e){results.push({name,status:'fail',error:e.message});return null;}};
const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date()),month=today.slice(0,7)+'-01';
try{
 const a=await checked(c.auth.signInWithPassword({email:s.LPG_TEST_EMAIL,password:s.LPG_TEST_PASSWORD}));
 const member=await checked(c.from('user_profiles').select('tenant_id,is_active').eq('user_id',a.user.id).single());assert(member.is_active);
 const filters={business_id:member.tenant_id,from:'2026-01-01',to:today,grain:'month'};
 for(const name of ['get_access_context','get_my_preferences','get_payment_wallets','get_business_catalogs','get_stove_product_types','get_inventory_valuation','get_financial_catalog','get_customer_filter_products','get_customer_overview','get_sales_overview','get_dashboard_snapshot','get_dashboard_activity','get_purchase_overview','get_employee_overview','get_attendance_configuration','get_logistics_summary','get_vehicle_expense_categories','list_lpg_brands','list_gas_plants','list_vehicles','get_permission_catalog','get_business_users','can_cancel_purchases'])await rpc(name);
 const customers=await rpc('get_customer_directory',{p_limit:5}),sales=await rpc('get_sales_directory',{p_limit:5}),purchases=await rpc('get_purchase_directory',{p_limit:5}),employees=await rpc('get_employee_directory',{p_limit:5}),vehicles=await rpc('get_vehicle_directory',{p_limit:5}),transits=await rpc('get_transit_directory',{p_limit:5}),services=await rpc('get_service_trip_directory',{p_limit:5});
 const dashboard=await rpc('get_dashboard_snapshot'),bottleDue=await rpc('get_customer_directory',{p_filters:{dues:'bottle'},p_limit:1}),paymentDue=await rpc('get_customer_directory',{p_filters:{dues:'payment'},p_limit:1});
 assert.equal(bottleDue?.total,dashboard?.attention.bottle_customers,'Dashboard bottle-due link and directory agree');
 assert.equal(paymentDue?.total,dashboard?.attention.customers,'Dashboard money-due link and directory agree');
 for(const name of ['get_wallet_ledger','get_financial_entries','get_finance_dues','get_inventory_history','get_vehicle_assignments','get_stock_alerts'])await rpc(name);
 const finance=await rpc('get_finance_analysis',{p_filters:filters});
 if(finance){for(const side of ['opening','closing'])assert(Math.abs(finance[side].assets-finance[side].liabilities-finance[side].equity)<.011,'Financial equation at '+side);}
 await rpc('get_accounting_health',{p_filters:filters});await rpc('get_accounting_breakdown',{p_filters:filters,p_group:'assets',p_side:'closing'});
 const journal=await rpc('get_analysis_details',{p_filters:filters,p_metric:'journal'});
 if(journal?.entries?.[0]?.journal_id)await rpc('get_journal_lines',{p_filters:filters,p_journal_id:journal.entries[0].journal_id});
 for(const kind of ['loans','assets','opening','obligations']){const records=await rpc('get_accounting_register',{p_kind:kind});if(['loans','assets'].includes(kind)&&records?.entries?.[0]){const row=records.entries[0],id=row.loan_id??row.asset_id;if(id)await rpc('get_accounting_history',{p_kind:kind==='loans'?'loan':'asset',p_id:id});}}
 const customer=customers?.entries?.[0]?.customer_id,sale=sales?.entries?.[0]?.sale_id,purchase=purchases?.entries?.[0]?.purchase_id,employee=employees?.entries?.[0]?.employee_id,vehicle=vehicles?.entries?.[0]?.vehicle_id,transit=transits?.entries?.[0]?.transit_id,service=services?.entries?.[0]?.service_trip_id;
 if(customer)for(const name of ['get_customer_balance','get_customer_bottle_balance','get_customer_transactions'])await rpc(name,{p_customer_id:customer});
 if(sale)for(const name of ['get_sale_details','get_sale_bottles','get_sale_settlement','get_sale_receipt'])await rpc(name,{p_sale_id:sale});
 if(purchase){await rpc('get_purchases_by_ids',{p_ids:[purchase]});await rpc('get_purchase_activity',{p_purchase_id:purchase});await rpc('get_purchase_settlement',{p_purchase_id:purchase});}
 if(employee){await rpc('get_employee_profile',{p_employee_id:employee});const salary=await rpc('get_employee_salary_month',{p_employee_id:employee,p_period:month});if(salary?.payments?.[0]?.payment_id)await rpc('get_employee_for_payment',{p_payment_id:salary.payments[0].payment_id});await rpc('get_employee_activity',{p_filters:{employee_id:employee}});await rpc('get_employee_attendance',{p_employee_id:employee,p_month:month});await rpc('get_employee_presence',{p_ids:[employee]});await rpc('get_attendance_history',{p_employee_id:employee});await rpc('get_attendance_edit',{p_employee_id:employee,p_day:today});}
 if(vehicle){await rpc('get_vehicle',{p_vehicle_id:vehicle});await rpc('get_accounting_history',{p_kind:'vehicle',p_id:vehicle});}
 for(const role of ['Driver','Helper'])await rpc('get_vehicle_crew_options',{p_role:role});
 if(transit)for(const name of ['get_transit','get_transit_payroll','get_trip_payment_wallets','get_operating_payments'])await rpc(name,{p_transit_id:transit});
 if(service){await rpc('get_service_trip',{p_service_trip_id:service});await rpc('get_service_trip_activity',{p_service_trip_id:service});await rpc('get_operating_payments',{p_service_trip_id:service});}
 const items=await checked(c.from('items').select('item_id').eq('business_category','lpg').limit(1));
 if(items[0]){const item=items[0].item_id;for(const name of ['get_product_inventory','get_inventory_cost_history','get_buying_price_history'])await rpc(name,{p_item_id:item});await rpc('get_monthly_commissions',{p_item_id:item,p_month:month});}
 const entries=await rpc('get_financial_entries',{p_limit:1});if(entries?.entries?.[0]?.entry_id)await rpc('get_financial_entry',{p_entry_id:entries.entries[0].entry_id});
 const cfg=await rpc('get_attendance_configuration');if(cfg?.devices?.[0]?.device_id)await rpc('get_attendance_users',{p_device_id:cfg.devices[0].device_id});
 const payments=await c.from('employee_payments').select('payment_id').limit(1);assert.equal(payments.error?.code,'42501','Direct private payroll records must remain inaccessible');
}catch(e){results.push({name:'sweep',status:'fail',error:String(e.message).replaceAll(s.LPG_TEST_PASSWORD,'[redacted]')});}
finally{
 await c.auth.signOut({scope:'local'});mkdirSync('.temp/feature-audit',{recursive:true});writeFileSync('.temp/feature-audit/read-endpoints.json',JSON.stringify(results,null,2));
 const unique=new Set(results.map(r=>r.name)),failed=results.filter(r=>r.status==='fail');console.log(`${results.length} read calls across ${unique.size} distinct endpoints; ${failed.length} failures`);for(const r of failed)console.log(r.name+': '+r.error);if(failed.length)process.exitCode=1;
}
