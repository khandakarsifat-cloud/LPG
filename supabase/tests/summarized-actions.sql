-- Same rolled-back fixture runs before/after the forward migration. Tuple bytes
-- exclude indexes/WAL/backups; latency is one engine sample, not a capacity claim.
create temporary table action_metrics(label text,headers bigint,lines bigint,tuple_bytes bigint,state_bytes bigint,elapsed_ms numeric);
create function pg_temp.measured_action(label text,expression text) returns jsonb language plpgsql as $$
declare t uuid:=app_private.current_tenant_id();h bigint;l bigint;b bigint;state_before bigint;started timestamptz;r jsonb;begin
 select count(*),coalesce(sum(pg_column_size(j)),0) into h,b from public.accounting_journals j where tenant_id=t;
 select count(*),b+coalesce(sum(pg_column_size(x)),0) into l,b from public.accounting_lines x where tenant_id=t;
 select coalesce(sum(pg_column_size(s)),0) into state_before from app_private.accounting_source_state s where tenant_id=t;
 started:=clock_timestamp();execute 'select '||expression into r;
 insert into action_metrics select label,(select count(*)-h from public.accounting_journals where tenant_id=t),
  (select count(*)-l from public.accounting_lines where tenant_id=t),
  (select coalesce(sum(pg_column_size(j)),0) from public.accounting_journals j where tenant_id=t)+
  (select coalesce(sum(pg_column_size(x)),0) from public.accounting_lines x where tenant_id=t)-b,
  (select coalesce(sum(pg_column_size(s)),0) from app_private.accounting_source_state s where tenant_id=t)-state_before,
  round(extract(epoch from clock_timestamp()-started)*1000,3);
 return r;
end $$;
insert into auth.users(id,email,is_anonymous) values('fc065000-0000-4000-8000-000000000001','event-storage@example.invalid',false);
select pg_temp.fixture_identity('fc065000-0000-4000-8000-000000000001');
select pg_temp.fixture_business('Summarized actions disposable acceptance','Event fixture owner');
do $$declare
 t uuid:=app_private.current_tenant_id();brand uuid;other_brand uuid;other_item uuid;plant uuid;truck uuid;driver uuid;
 cash uuid;bank uuid;mobile uuid;product uuid;products uuid[];n integer;scale integer;prefix text;pid uuid;sid uuid;rev integer;
 lines jsonb;goods jsonb;bottles jsonb;body jsonb;payments jsonb;r jsonb;request uuid;d date:=(now() at time zone 'Asia/Dhaka')::date;
 loan uuid;asset uuid;bonus uuid;ft uuid;entry uuid;trip uuid;salaried uuid;expense_before numeric;stove uuid;stove_type uuid;
begin
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Event company') returning brand_id into brand;
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Different returned company') returning brand_id into other_brand;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,other_brand,12,'22mm') returning item_id into other_item;
 perform public.set_product_buying_price(jsonb_build_object('item_id',other_item,'price_type','bottle','is_manual',true,'price',1800,'reason','Returned company price','expected',null),gen_random_uuid());
 insert into public.gas_plants(tenant_id,brand_id,plant_name) values(t,brand,'Event plant') returning plant_id into plant;
 insert into public.employee_types(tenant_id,name) values(t,'Driver') on conflict do nothing;
 r:=public.save_employee(jsonb_build_object('name','Event driver','employee_type_name','Driver','business_unit','truck_business',
  'phones',jsonb_build_array(jsonb_build_object('phone','01799000888','is_primary',true)),
  'terms',jsonb_build_object('effective_from',d,'monthly_salary',0,'is_active',true)),gen_random_uuid());driver:=(r->>'employee_id')::uuid;
 r:=public.save_vehicle(jsonb_build_object('name','Event truck','serial_no','EVENT-STORAGE','capacity',500,'driver_employee_id',driver,'book_value',100000,'funding','capital'),gen_random_uuid());truck:=(r->>'vehicle_id')::uuid;
 select wallet_id into cash from public.wallets where tenant_id=t and type='cash';
 select wallet_id into bank from public.wallets where tenant_id=t and type='dealership';
 select wallet_id into mobile from public.wallets where tenant_id=t and type='bkash';
 foreach scale in array array[1,12] loop
  prefix:=case when scale=1 then 'small' else 'large' end;products:='{}';lines:='[]';goods:='[]';bottles:='[]';
  for n in 1..scale loop
   insert into public.business_weights(tenant_id,size_kg) values(t,10+n+scale) on conflict do nothing;
   insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,10+n+scale,'22mm') returning item_id into product;
   products:=array_append(products,product);
   insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price) values(t,product,'retail','refill',1250),(t,product,'retail','package',3000);
   perform public.adjust_inventory(jsonb_build_object('item_id',product,'kind','capital','filled_quantity',0,'empty_quantity',2,'empty_unit_cost',1200,'reason','Original owned shells'),gen_random_uuid());
   lines:=lines||jsonb_build_array(jsonb_build_object('item_id',product,'quantity',4,'bottle_quantity',2,'unit_price',800,'bottle_unit_price',1600));
   goods:=goods||jsonb_build_array(jsonb_build_object('item_id',product,'type','refill','quantity',1,'unit_price',1250),
    jsonb_build_object('item_id',product,'type','package','quantity',1,'unit_price',3000),jsonb_build_object('item_id',product,'type','empty_return','quantity',1,'unit_price',0));
   if n<=scale/2 then bottles:=bottles||jsonb_build_array(jsonb_build_object('received_item_id',product,'quantity',1));end if;
  end loop;
  body:=jsonb_build_object('plant_id',plant,'vehicle_id',truck,'transport_cost',100*scale,'labour_cost',50*scale,'items',lines,'request_id',gen_random_uuid());
  r:=pg_temp.measured_action(prefix||'.purchase_draft',format('public.create_purchase(%L::jsonb)',body::text));pid:=(r->>'purchase_id')::uuid;
  perform pg_temp.measured_action(prefix||'.treasury_transfer',format('public.move_wallet_money(%L::jsonb,%L::uuid)',jsonb_build_object('action','transfer','wallet_id',cash,'destination_id',bank,'amount',10,'reason','Principal only')::text,gen_random_uuid()));
  select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
  perform pg_temp.measured_action(prefix||'.purchase_dispatch',format('public.dispatch_purchase(%L::uuid,%s)',pid,rev));
  select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
  perform pg_temp.measured_action(prefix||'.purchase_receipt',format('public.receive_purchase(%L::uuid,%s)',pid,rev));
  payments:=jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',500*scale),jsonb_build_object('wallet_id',bank,'amount',500*scale),jsonb_build_object('wallet_id',mobile,'amount',500*scale));
  perform pg_temp.measured_action(prefix||'.supplier_split_payment',format('public.record_purchase_payment(%L::uuid,%L::jsonb,%L::uuid)',pid,payments::text,gen_random_uuid()));
  request:=gen_random_uuid();
  body:=jsonb_build_object('lines',bottles,'note','Partial bottles at checkout');
  r:=pg_temp.measured_action(prefix||'.checkout',format('public.create_pos_sale(%L,%L,null,null,%L,0,0,%L,%L::jsonb,p_request_id=>%L::uuid,p_payments=>%L::jsonb,p_bottles=>%L::jsonb)',
   '017990009'||lpad(scale::text,2,'0'),'Event buyer','retail','Event storage fixture',goods::text,request,payments::text,body::text));sid:=(r->>'sale_id')::uuid;
  perform pg_temp.measured_action(prefix||'.checkout_retry',format('public.create_pos_sale(%L,%L,null,null,%L,0,0,%L,%L::jsonb,p_request_id=>%L::uuid,p_payments=>%L::jsonb,p_bottles=>%L::jsonb)',
   '017990009'||lpad(scale::text,2,'0'),'Event buyer','retail','Event storage fixture',goods::text,request,payments::text,body::text));
  perform pg_temp.measured_action(prefix||'.partial_collection',format('public.collect_sale_payment(%L::uuid,%L::jsonb,%L::uuid)',sid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',250*scale))::text,gen_random_uuid()));
  body:=jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',other_item,'quantity',scale-scale/2,'acknowledged',true)),'note','Different actual company settles remaining bottles');
  perform pg_temp.measured_action(prefix||'.delayed_cross_company_bottles',format('public.collect_sale_bottles(%L::uuid,%L::jsonb,%L::uuid)',sid,body::text,gen_random_uuid()));
  perform pg_temp.measured_action(prefix||'.final_collection',format('public.collect_sale_payment(%L::uuid,%L::jsonb,%L::uuid)',sid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',2500*scale))::text,gen_random_uuid()));
  if (select total_amount+additional_charges-paid_amount from public.sales where tenant_id=t and sale_id=sid)<>0 then raise exception 'Sale money did not settle';end if;
  if (select coalesce(sum(amount),0) from public.accounting_lines where tenant_id=t and account='bottle_receivable' and entity_id=sid)<>0 then raise exception 'Bottle carrying claim did not settle';end if;
  -- Complete the existing delivery so the same vehicle can serve the next case.
  select tr.transit_id,tr.revision into product,rev from public.transits tr where tr.tenant_id=t and tr.purchase_id=pid;
  perform public.transition_transit(product,'complete',rev);
 end loop;
 -- POS and Finance already have separate request registries. The same UUID in
 -- those namespaces must not collide in the derived journal primary key.
 perform pg_temp.measured_action('identity.existing_request_namespaces',format('public.accounting_operation(%L::jsonb,%L::uuid)',jsonb_build_object('action','capital','amount',1,'wallet_id',cash,'date',d,'description','Distinct Finance request namespace')::text,request));
 body:=jsonb_build_object('employee_id',driver,'kind','bonus','bonus_name','Named safety award','payment_date',d,'payments',jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100)));
 r:=pg_temp.measured_action('payroll.bonus_and_payment',format('public.employee_payment_operation(%L::jsonb,%L::uuid)',jsonb_build_object('action','pay','items',jsonb_build_array(body))::text,gen_random_uuid()));bonus:=(r->'payment_ids'->>0)::uuid;
 perform pg_temp.measured_action('payroll.returned_bonus',format('public.employee_payment_operation(%L::jsonb,%L::uuid)',jsonb_build_object('action','reverse_payment','payment_id',bonus,'payment_date',d,'reason','Award funds returned')::text,gen_random_uuid()));
 r:=pg_temp.measured_action('payroll.salary_recognition',format('public.save_employee(%L::jsonb,%L::uuid)',jsonb_build_object('name','Salaried fixture worker','employee_type_name','General Staff','business_unit','gas_business',
  'phones',jsonb_build_array(jsonb_build_object('phone','01799000777','is_primary',true)),
  'terms',jsonb_build_object('effective_from',date_trunc('month',d)::date,'monthly_salary',1200,'is_active',true))::text,gen_random_uuid()));salaried:=(r->>'employee_id')::uuid;
 select coalesce(sum(amount),0) into expense_before from public.accounting_lines where tenant_id=t and account='employee_expense';
 body:=jsonb_build_object('employee_id',salaried,'kind','salary','period',date_trunc('month',d)::date,'payment_date',d,'payments',jsonb_build_array(jsonb_build_object('wallet_id',bank,'amount',100)));
 perform pg_temp.measured_action('payroll.partial_salary',format('public.employee_payment_operation(%L::jsonb,%L::uuid)',jsonb_build_object('action','pay','items',jsonb_build_array(body))::text,gen_random_uuid()));
 body:=jsonb_set(body,'{period}',to_jsonb((date_trunc('month',d)+interval '1 month')::date));
 perform pg_temp.measured_action('payroll.future_advance',format('public.employee_payment_operation(%L::jsonb,%L::uuid)',jsonb_build_object('action','pay','items',jsonb_build_array(body))::text,gen_random_uuid()));
 if (select coalesce(sum(amount),0) from public.accounting_lines where tenant_id=t and account='employee_expense')<>expense_before then raise exception 'Salary payments recognized expense again';end if;
 body:=jsonb_build_object('vehicle_id',truck,'destination','Metric delivery','client_name','Metric client','fee',1000,'description','Collected at departure');
 r:=pg_temp.measured_action('logistics.recognize_and_collect',format('public.create_custom_transit(%L::jsonb,%L::uuid)',body::text,gen_random_uuid()));trip:=(r->>'transit_id')::uuid;
 select revision into rev from public.transits where tenant_id=t and transit_id=trip;
 body:='{"driver_cost":200,"helper_cost":0,"oil_cost":100,"others_cost":0,"additional_costs":[]}';
 perform pg_temp.measured_action('logistics.costs_and_immediate_payment',format('public.transition_transit(%L::uuid,%L,%s,%L::jsonb)',trip,'complete',rev,body::text));
 body:=jsonb_build_object('action','loan_lend','amount',100.01,'lender','Metric borrower','wallet_id',cash,'date',d,'description','Metric lending');
 r:=pg_temp.measured_action('lending.issue',format('public.accounting_operation(%L::jsonb,%L::uuid)',body::text,gen_random_uuid()));loan:=(r->>'id')::uuid;
 body:=jsonb_build_object('action','loan_collect','loan_id',loan,'amount',40.01,'wallet_id',bank,'date',d,'description','Metric partial collection');
 perform pg_temp.measured_action('lending.partial_collection',format('public.accounting_operation(%L::jsonb,%L::uuid)',body::text,gen_random_uuid()));
 body:=jsonb_build_object('action','asset_register','name','Metric equipment','kind','equipment','amount',1000,'funding','wallet','wallet_id',cash,'date',d,'description','Equipment acquired');
 r:=pg_temp.measured_action('assets.wallet_purchase',format('public.accounting_operation(%L::jsonb,%L::uuid)',body::text,gen_random_uuid()));asset:=(r->>'id')::uuid;
 body:=jsonb_build_object('action','asset_depreciate','asset_id',asset,'amount',100,'date',d,'description','Explicit depreciation');
 perform pg_temp.measured_action('assets.depreciation',format('public.accounting_operation(%L::jsonb,%L::uuid)',body::text,gen_random_uuid()));
 body:=jsonb_build_object('action','asset_dispose','asset_id',asset,'method','sold','proceeds',800,'wallet_id',cash,'date',d,'description','Equipment sold');
 perform pg_temp.measured_action('assets.disposal',format('public.accounting_operation(%L::jsonb,%L::uuid)',body::text,gen_random_uuid()));
 insert into public.financial_types(tenant_id,name,origin,account,allocations) values(t,'Original expense label','custom','operating_expense','{"lpg":33.33,"stove":66.67}') returning type_id into ft;
 body:=jsonb_build_object('type_id',ft,'expected_revision',1,'wallet_id',cash,'amount',100.01,'date',d,'description','Metric allocated expense');
 r:=pg_temp.measured_action('finance.allocated_expense',format('public.record_financial_entry(%L::jsonb,%L::uuid)',body::text,gen_random_uuid()));entry:=(r->>'entry_id')::uuid;
 update public.financial_types set name='Renamed future label',revision=revision+1 where tenant_id=t and type_id=ft;
 body:=jsonb_build_object('reversal_of',entry,'wallet_id',bank,'amount',40.01,'date',d,'description','Metric returned funds');
 perform pg_temp.measured_action('finance.partial_return',format('public.record_financial_entry(%L::jsonb,%L::uuid)',body::text,gen_random_uuid()));
 select type_id into stove_type from public.stove_product_types where tenant_id=t and is_active order by type_id limit 1;
 stove:=(public.save_stove_product(jsonb_build_object('name','Direct receipt fixture stove','type_id',stove_type),gen_random_uuid())->>'item_id')::uuid;
 body:=jsonb_build_object('business_category','stove','supplier_name','Direct receipt supplier','request_id',gen_random_uuid(),'labour_cost',100,'items',jsonb_build_array(jsonb_build_object('item_id',stove,'quantity',3,'unit_price',500,'bottle_quantity',0,'bottle_unit_price',0)));
 r:=pg_temp.measured_action('stove.purchase_draft',format('public.create_purchase(%L::jsonb)',body::text));pid:=(r->>'purchase_id')::uuid;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 perform pg_temp.measured_action('stove.direct_receipt',format('public.receive_purchase(%L::uuid,%s)',pid,rev));
 payments:=jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',500),jsonb_build_object('wallet_id',bank,'amount',500));
 perform pg_temp.measured_action('stove.supplier_payment',format('public.record_purchase_payment(%L::uuid,%L::jsonb,%L::uuid)',pid,payments::text,gen_random_uuid()));
 if exists(select 1 from public.accounting_lines where tenant_id=t group by journal_id,business_category having sum(amount)<>0)
  then raise exception 'A business journal does not balance';end if;
 for product in select item_id from public.items where tenant_id=t loop
  if app_private.reconcile_record(t,'inventory',product) then raise exception 'Source/FIFO/control-account reconciliation failed';end if;
 end loop;
 if app_private.reconcile_record(t,'wallet',cash) or app_private.reconcile_record(t,'wallet',bank) or app_private.reconcile_record(t,'wallet',mobile) then raise exception 'Wallet reconciliation failed';end if;
 if exists(select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='app_private' and p.proname='begin_accounting_action') then
  if exists(select 1 from action_metrics where label like '%.purchase_draft' or label like '%.checkout_retry' or label like '%.treasury_transfer' having sum(headers)<>0) then raise exception 'Nonfinancial draft, transfer or retry posted again';end if;
  if exists(select 1 from action_metrics where label not like '%.purchase_draft' and label not like '%.checkout_retry' and label not like '%.treasury_transfer' and headers<>1) then raise exception 'Financial action did not produce exactly one journal';end if;
  r:=public.get_accounting_breakdown(jsonb_build_object('from',d,'to',d,'source','sale','search','Event storage fixture'),'all','closing','history',0,100);
  if (r->>'total')::integer<>8 or exists(select 1 from jsonb_array_elements(r->'entries') x where not (x->>'event_row')::boolean)
   then raise exception 'Activity must contain one row per action with source-note search';end if;
  r:=public.get_accounting_breakdown(jsonb_build_object('from',d,'to',d,'source','sale','search','Event company','account','customer_receivable'),'all','closing','history',0,100);
  if (r->>'total')::integer<>6 or (r->>'filtered_movement')::numeric<>0 then raise exception 'Company search and selected account movements did not reconcile';end if;
  r:=public.get_accounting_breakdown(jsonb_build_object('from',d,'to',d,'search','Metric lending'),'all','closing','history',0,100);
  if (r->>'total')::integer<>2 or not exists(select 1 from jsonb_array_elements(r->'entries') x where x->>'description'='Metric lending' and (x->>'amount')::numeric=100.01)
   then raise exception 'Action value was split or double-counted across lines';end if;
  r:=public.get_accounting_breakdown(jsonb_build_object('from',d,'to',d,'search','Metric lending','min','80'),'all','closing','history',0,100);
  if (r->>'total')::integer<>1 or (r->'entries'->0->>'amount')::numeric<>100.01 then raise exception 'Minimum amount filtered split lines instead of action value';end if;
  r:=public.get_accounting_breakdown(jsonb_build_object('from',d,'to',d,'search','Metric lending','account','loan_receivable','min','80'),'all','closing','history',0,100);
  if (r->>'total')::integer<>1 or (r->>'filtered_movement')::numeric<>100.01 then raise exception 'Scoped action amount filter did not reconcile';end if;
  if (app_private.position_from_balances(jsonb_build_array(jsonb_build_object('tenant_id',t,'account','inventory_lpg','entity_id',products[1],'amount',100),jsonb_build_object('tenant_id',t,'account','inventory_lpg','entity_id',null,'amount',-50)))->>'liabilities')::numeric<>0
   then raise exception 'Mixed historical product and summarized inventory was misclassified';end if;
  begin
   perform app_private.begin_accounting_action('injected_missing_finalization');
   perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',cash,'amount',1,'business','lpg','reason','Rolled-back collector fault'),gen_random_uuid());
   set constraints all immediate;
   raise exception 'Missing finalization was accepted';
  exception when others then
   if sqlerrm<>'Financial action was not finalized' then raise;end if;
  end;
  if nullif(current_setting('lpg.accounting_action',true),'') is not null then raise exception 'Collector survived rollback';end if;
  if exists(select 1 from action_metrics metrics where metrics.label in ('payroll.bonus_and_payment','payroll.returned_bonus','assets.wallet_purchase','logistics.recognize_and_collect') and metrics.lines<>2)
   then raise exception 'Immediate settlement retained redundant clearing lines';end if;
  r:=public.get_accounting_breakdown(jsonb_build_object('from',d,'to',d,'search','Metric allocated expense'),'all','closing','history',0,100);
  if (r->>'total')::integer<>1 or r->'entries'->0->>'type_name'<>'Original expense label' then raise exception 'Custom type snapshot changed after renaming defaults';end if;
 end if;
end $$;
with report as(select public.get_finance_analysis(jsonb_build_object('from',date_trunc('month',now() at time zone 'Asia/Dhaka')::date,'to',(now() at time zone 'Asia/Dhaka')::date,'category','all','grain','day')) value)
select (select jsonb_object_agg(label,jsonb_build_object('headers',headers,'lines',lines,'tuple_bytes',tuple_bytes,'source_state_bytes',state_bytes,'elapsed_ms',elapsed_ms)) from action_metrics)||
 jsonb_build_object('_reports',jsonb_build_object('opening',(value->'opening')-'accounts','closing',(value->'closing')-'accounts','totals',value->'totals','period_values',value->'period_values','cash_categories',
 (select jsonb_agg(x order by x->>'category') from jsonb_array_elements(value->'cash_categories')x),
 'business_positions',(select jsonb_agg(jsonb_build_object('category',x->>'category','opening',(x->'opening')-'accounts','closing',(x->'closing')-'accounts') order by x->>'category') from jsonb_array_elements(value->'business_positions')x),'trend',value->'trend')) from report;
