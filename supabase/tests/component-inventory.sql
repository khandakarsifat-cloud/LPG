-- Current component contracts. Run only in the disposable clone.
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'FAIL: %',message;end if;end$$;
grant execute on function pg_temp.assert(boolean,text) to authenticated;
select pg_temp.assert(not exists(
 select 1 from information_schema.columns where table_schema in('public','app_private')
 and column_name ~ '(filled|empty)'
),'No active table or view uses the previous stock fields');
select pg_temp.assert(to_regclass('app_private.fifo_positions') is null
 and to_regclass('app_private.fifo_position_effects') is null
 and to_regclass('app_private.fifo_component_layers') is null
 and (select relkind='r' from pg_class where oid='app_private.fifo_layers'::regclass),
 'One canonical component FIFO table');
select pg_temp.assert(not exists(
 select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in('public','app_private') and p.prosrc ~ '(filled_|empty_|fifo_positions|fifo_component_layers|fifo_position_effects)'
),'Active functions use only the component contract');
insert into auth.users(id,email,is_anonymous)
values('fc071000-0000-4000-8000-000000000001','component-owner@example.invalid',false);
select pg_temp.fixture_identity('fc071000-0000-4000-8000-000000000001');
select pg_temp.fixture_business('Canonical component disposable acceptance','Component owner');
create temp table component_security_ids(key text,value uuid);
grant select on component_security_ids to authenticated,anon;

do $$declare
 t uuid:=app_private.current_tenant_id();brand uuid;other_brand uuid;item uuid;other_item uuid;plant uuid;
 driver uuid;vehicle uuid;purchase uuid;cancelled uuid;package_sale uuid;refill_sale uuid;
 rev integer;cash uuid;request uuid;payload jsonb;result jsonb;before_layers jsonb;after_layers jsonb;
 before_journals integer;before_costs integer;claim numeric;report jsonb;stove uuid;stove_type uuid;
begin
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Component Gas') returning brand_id into brand;
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Other Component Gas') returning brand_id into other_brand;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,12,'22mm') returning item_id into item;
 insert into component_security_ids values('item',item);
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,other_brand,12,'22mm') returning item_id into other_item;
 insert into public.gas_plants(tenant_id,brand_id,plant_name) values(t,brand,'Component plant') returning plant_id into plant;
 insert into public.employee_types(tenant_id,name) values(t,'Driver') on conflict do nothing;
 driver:=(public.save_employee(jsonb_build_object('name','Component driver','employee_type_name','Driver',
  'business_unit','truck_business','phones',jsonb_build_array(jsonb_build_object('phone','01700000710','is_primary',true)),
  'terms',jsonb_build_object('effective_from',(now() at time zone 'Asia/Dhaka')::date,'monthly_salary',0,'is_active',true)),gen_random_uuid())->>'employee_id')::uuid;
 vehicle:=(public.save_vehicle(jsonb_build_object('name','Component truck','serial_no','COMPONENT-ONLY','capacity',100,
  'driver_employee_id',driver,'book_value',1000,'funding','capital'),gen_random_uuid())->>'vehicle_id')::uuid;
 select wallet_id into cash from public.wallets where tenant_id=t and type='cash';
 perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',cash,'classification','capital',
  'business','lpg','amount',50000,'reason','Component acceptance cash'),gen_random_uuid());
 perform public.adjust_inventory(jsonb_build_object('item_id',item,'kind','capital','bottle_quantity',3,
  'bottle_unit_cost',100,'reason','First Bottle acquisition'),gen_random_uuid());
 perform public.adjust_inventory(jsonb_build_object('item_id',item,'kind','capital','bottle_quantity',4,
  'bottle_unit_cost',120,'reason','Second Bottle acquisition'),gen_random_uuid());
 perform public.set_product_buying_price(jsonb_build_object('item_id',other_item,'price_type','bottle','is_manual',true,
  'price',175,'reason','Incoming Bottle reference','expected',null),gen_random_uuid());
 select jsonb_agg(to_jsonb(l) order by layer_id) into before_layers from app_private.fifo_layers l where tenant_id=t and item_id=item;
 before_journals:=(select count(*) from public.accounting_journals where tenant_id=t);
 before_costs:=(select count(*) from public.inventory_cost_entries where tenant_id=t);
 payload:=jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',vehicle,
  'items',jsonb_build_array(jsonb_build_object('item_id',item,'quantity',5,'bottle_quantity',1,'unit_price',700,'bottle_unit_price',150)));
 purchase:=(public.create_purchase(payload)->>'purchase_id')::uuid;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=purchase;
 perform public.dispatch_purchase(purchase,rev);
 select jsonb_agg(to_jsonb(l) order by layer_id) into after_layers from app_private.fifo_layers l where tenant_id=t and item_id=item;
 perform pg_temp.assert(before_layers=after_layers,'Dispatch makes no FIFO mutation');
 perform pg_temp.assert(before_journals=(select count(*) from public.accounting_journals where tenant_id=t)
  and before_costs=(select count(*) from public.inventory_cost_entries where tenant_id=t),'Zero-fee dispatch has no finance or cost event');
 perform pg_temp.assert((select gas_quantity=0 and bottle_quantity=3 from public.items where tenant_id=t and item_id=item),'Dispatch changes only on-hand Bottle');
 perform pg_temp.assert((select sum(quantity)=4 from app_private.purchase_bottle_custody where tenant_id=t and settled_movement_id is null),'Four Bottles held in transit');
 select revision into rev from public.purchases where tenant_id=t and purchase_id=purchase;
 perform public.receive_purchase(purchase,rev);
 perform pg_temp.assert((select gas_quantity=5 and bottle_quantity=8 from public.items where tenant_id=t and item_id=item),'Receipt has five Gas and eight owned Bottles');
 perform pg_temp.assert((select count(*)=1 and sum(quantity)=5 and sum(value)=3500 from app_private.fifo_layers where tenant_id=t and component='gas'),'One Gas acquisition');
 perform pg_temp.assert((select count(*)=3 and sum(quantity)=8 and sum(value)=930 from app_private.fifo_layers where tenant_id=t and component='bottle'),'Only newly bought Bottle creates another layer');
 perform pg_temp.assert(not exists(select 1 from app_private.purchase_bottle_custody where tenant_id=t and settled_movement_id is null),'Receipt clears inventory transit');
 perform pg_temp.assert((app_private.component_inventory_evidence(t,item)->>'consistent')::boolean,'Receipt reconciles stock and FIFO');

 payload:=jsonb_set(payload,'{request_id}',to_jsonb(gen_random_uuid()));
 payload:=jsonb_set(payload,'{items,0,quantity}','2');
 payload:=jsonb_set(payload,'{items,0,bottle_quantity}','0');
 payload:=jsonb_set(payload,'{items,0,bottle_unit_price}','0');
 cancelled:=(public.create_purchase(payload)->>'purchase_id')::uuid;
 select jsonb_agg(to_jsonb(l) order by layer_id) into before_layers from app_private.fifo_layers l where tenant_id=t and item_id=item;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=cancelled;
 perform public.dispatch_purchase(cancelled,rev);
 select revision into rev from public.purchases where tenant_id=t and purchase_id=cancelled;
 perform public.initiate_purchase_cancellation(cancelled,rev,'CANCEL',gen_random_uuid());
 select jsonb_agg(to_jsonb(l) order by layer_id) into after_layers from app_private.fifo_layers l where tenant_id=t and item_id=item;
 perform pg_temp.assert(before_layers=after_layers,'Purchase cancellation releases transit without touching FIFO');

 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price)
 values(t,item,'retail','refill',900),(t,item,'retail','package',1400);
 result:=public.create_pos_sale('01700000711','Package buyer',null,null,'retail',0,0,'Component package sale',
  jsonb_build_array(jsonb_build_object('item_id',item,'type','package','quantity',1,'unit_price',1400)),
  p_request_id=>gen_random_uuid(),p_payments=>'[]',p_bottles=>'{"lines":[]}');
 package_sale:=(result->>'sale_id')::uuid;
 perform pg_temp.assert((select sum(x.value)=800 from app_private.fifo_consumptions x
  join public.inventory_movements m using(tenant_id,movement_id) where x.tenant_id=t and m.reference_id=package_sale),'Package consumes independent Gas 700 plus Bottle 100');
 request:=gen_random_uuid();
 result:=public.create_pos_sale('01700000712','Refill buyer',null,null,'retail',0,0,'Two Gas with Bottle replacement obligation',
  jsonb_build_array(jsonb_build_object('item_id',item,'type','refill','quantity',2,'unit_price',900)),
  p_request_id=>request,p_payments=>'[]',p_bottles=>'{"lines":[]}');
 refill_sale:=(result->>'sale_id')::uuid;
 perform pg_temp.assert(public.create_pos_sale('01700000712','Refill buyer',null,null,'retail',0,0,'Two Gas with Bottle replacement obligation',
  jsonb_build_array(jsonb_build_object('item_id',item,'type','refill','quantity',2,'unit_price',900)),
  p_request_id=>request,p_payments=>'[]',p_bottles=>'{"lines":[]}')=result,'Exact sale retry');
 perform pg_temp.assert((select gas_quantity=2 and bottle_quantity=5 from public.items where tenant_id=t and item_id=item),'Sales deduct Gas and Bottle independently');
 perform public.collect_sale_bottles(refill_sale,jsonb_build_object('lines',jsonb_build_array(
  jsonb_build_object('received_item_id',other_item,'quantity',1,'acknowledged',true))),gen_random_uuid());
 perform pg_temp.assert((select gas_quantity=0 and bottle_quantity=1 from public.items where tenant_id=t and item_id=other_item),'Cross-product receipt adds only the actual Bottle');
 select sum(amount) into claim from public.accounting_lines where tenant_id=t and account='bottle_receivable' and entity_id=refill_sale;
 perform pg_temp.assert(claim=100,'One historical Bottle claim remains after partial receipt');
 report:=public.get_product_performance('lpg');
 perform pg_temp.assert((report->'totals'->>'cogs')::numeric=2200,'Independent Package 800 plus Refill Gas COGS 1400');
 perform public.reverse_sale(refill_sale,'Restore original components','CANCEL',gen_random_uuid());
 perform public.reverse_sale(package_sale,'Restore original components','CANCEL',gen_random_uuid());
 perform pg_temp.assert((select gas_quantity=5 and bottle_quantity=8 from public.items where tenant_id=t and item_id=item)
  and (select gas_quantity=0 and bottle_quantity=0 from public.items where tenant_id=t and item_id=other_item),'Sale cancellation restores original component quantities');
 perform pg_temp.assert((app_private.component_inventory_evidence(t,item)->>'consistent')::boolean,'Exact source/FIFO restoration');
 -- Two commercial lines for the same SKU may consume the same acquisition layer.
 result:=public.create_pos_sale('01700000716','Mixed commercial buyer',null,null,'retail',0,0,'Same product Package and Refill',
  jsonb_build_array(jsonb_build_object('item_id',item,'type','package','quantity',1,'unit_price',1400),
   jsonb_build_object('item_id',item,'type','refill','quantity',1,'unit_price',900)),
  p_request_id=>gen_random_uuid(),p_payments=>'[]',p_bottles=>'{"lines":[]}');
 perform public.reverse_sale((result->>'sale_id')::uuid,'Restore shared acquisition slices','CANCEL',gen_random_uuid());
 perform pg_temp.assert((app_private.component_inventory_evidence(t,item)->>'consistent')::boolean,'Mixed-line cancellation restores each original layer once');
 perform pg_temp.assert(not app_private.reconcile_record(t,'inventory',item),'Inventory and finance reconcile');
 perform pg_temp.assert((public.get_fifo_stock(item)->'summary'->>'gas')::integer=5,'Component FIFO read contract');
 perform public.get_inventory_history();
 perform public.get_product_inventory(item);
 perform public.get_inventory_cost_history(item);
 perform public.get_inventory_valuation();
 perform public.get_stock_alerts();

 select type_id into stove_type from public.stove_product_types where tenant_id=t and is_active limit 1;
 stove:=(public.save_stove_product(jsonb_build_object('name','Component Stove','type_id',stove_type),gen_random_uuid())->>'item_id')::uuid;
 perform public.adjust_inventory(jsonb_build_object('item_id',stove,'kind','capital','unit_quantity',2,'unit_unit_cost',500,'reason','Stove unit capital'),gen_random_uuid());
 perform pg_temp.assert((select gas_quantity=0 and bottle_quantity=0 and unit_quantity=2 from public.items where tenant_id=t and item_id=stove),'Stove has its own unit component');
 perform pg_temp.assert((app_private.component_inventory_evidence(t,stove)->>'consistent')::boolean,'Stove component reconciliation');
 -- Backdated Bottle acquisition replays both component queues, with dated corrections.
 perform public.adjust_inventory(jsonb_build_object('item_id',item,'kind','capital','bottle_quantity',1,
  'bottle_unit_cost',90,'reason','Backdated Bottle acquisition','date',(now() at time zone 'Asia/Dhaka')::date-1),gen_random_uuid());
 perform pg_temp.assert((app_private.component_inventory_evidence(t,item)->>'consistent')::boolean,'Backdated component replay conserves quantity and value');
 perform pg_temp.assert((select gas_quantity=5 and bottle_quantity=9 from public.items where tenant_id=t and item_id=item),'Backdated acquisition adds one Bottle');
 perform pg_temp.assert(not app_private.reconcile_record(t,'inventory',item),'Backdated component replay reconciles');
 -- Live issues must be revalued when a cheaper acquisition precedes them.
 result:=public.create_pos_sale('01700000713','Replay buyer',null,null,'retail',0,0,'Active backdated issue',
  jsonb_build_array(jsonb_build_object('item_id',item,'type','package','quantity',1,'unit_price',1400)),
  p_request_id=>gen_random_uuid(),p_payments=>'[]',p_bottles=>'{"lines":[]}');
 package_sale:=(result->>'sale_id')::uuid;
 perform public.adjust_inventory(jsonb_build_object('item_id',item,'kind','capital','gas_quantity',1,'bottle_quantity',1,
  'gas_unit_cost',600,'bottle_unit_cost',80,'reason','Earlier two component acquisition','date',(now() at time zone 'Asia/Dhaka')::date-2),gen_random_uuid());
 perform pg_temp.assert((select sum(x.value)=680 from app_private.fifo_consumptions x join public.inventory_movements m using(tenant_id,movement_id)
  where x.tenant_id=t and m.reference_id=package_sale),'Backdated active issue uses earlier independent Gas and Bottle costs');
 perform pg_temp.assert((app_private.component_inventory_evidence(t,item)->>'consistent')::boolean,'Active backdated issue reconciles corrected source journals');
 perform public.reverse_sale(package_sale,'Restore revalued issues','CANCEL',gen_random_uuid());
 perform pg_temp.assert((app_private.component_inventory_evidence(t,item)->>'consistent')::boolean,'Cancellation restores the revalued original components');
 -- Reversal cannot remove an actual returned Bottle already issued by another sale.
 perform public.adjust_inventory(jsonb_build_object('item_id',other_item,'kind','capital','gas_quantity',1,'bottle_quantity',1,
  'gas_unit_cost',650,'bottle_unit_cost',90,'reason','Cross-product issue capital'),gen_random_uuid());
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price) values(t,other_item,'retail','package',1400);
 result:=public.create_pos_sale('01700000714','Immediate return buyer',null,null,'retail',0,0,'Actual cross-product Bottle receipt',
  jsonb_build_array(jsonb_build_object('item_id',item,'type','refill','quantity',1,'unit_price',900)),
  p_request_id=>gen_random_uuid(),p_payments=>'[]',p_bottles=>jsonb_build_object('lines',jsonb_build_array(
   jsonb_build_object('received_item_id',other_item,'quantity',1,'acknowledged',true))));
 refill_sale:=(result->>'sale_id')::uuid;
 perform public.adjust_inventory(jsonb_build_object('item_id',other_item,'kind','lost','bottle_quantity',-1,
  'reason','Consume earliest independent Bottle'),gen_random_uuid());
 perform public.create_pos_sale('01700000715','Return layer consumer',null,null,'retail',0,0,'Consume actual return Bottle',
  jsonb_build_array(jsonb_build_object('item_id',other_item,'type','package','quantity',1,'unit_price',1400)),
  p_request_id=>gen_random_uuid(),p_payments=>'[]',p_bottles=>'{"lines":[]}');
 begin
  perform public.reverse_sale(refill_sale,'Must reject consumed incoming Bottle','CANCEL',gen_random_uuid());
  raise exception 'FAIL: consumed actual-return layer cancellation was accepted';
 exception when others then
  if sqlerrm like 'FAIL:%' then raise;end if;
  perform pg_temp.assert(sqlerrm ~* '(consumed|revers|used)', 'Consumed-return cancellation has the source guard');
 end;
 perform pg_temp.assert((app_private.component_inventory_evidence(t,item)->>'consistent')::boolean
  and (app_private.component_inventory_evidence(t,other_item)->>'consistent')::boolean,'Rejected cancellation leaves all component and finance evidence intact');
 perform public.set_product_buying_price(jsonb_build_object('item_id',other_item,'price_type','bottle','is_manual',true,
  'price',250,'reason','Later current reference','expected',(select history_id from public.product_buying_price_history
   where tenant_id=t and item_id=other_item and price_type='bottle' order by effective_at desc,entry_no desc limit 1)),gen_random_uuid());
 perform public.adjust_inventory(jsonb_build_object('item_id',item,'kind','capital','bottle_quantity',1,
  'bottle_unit_cost',70,'reason','Replay after changed incoming reference','date',(now() at time zone 'Asia/Dhaka')::date-3),gen_random_uuid());
 perform pg_temp.assert((select count(*)=1 and min(l.value)=175 from app_private.fifo_layers l
  join public.inventory_movements m using(tenant_id,movement_id) where l.tenant_id=t and m.reference_id=refill_sale
  and m.reference_type='sale' and m.bottle_change>0),'Replay retains immutable actual-return buying price');
 -- Stove is a Unit component through purchase, sale, reversal and received cancellation.
 payload:=jsonb_build_object('request_id',gen_random_uuid(),'business_category','stove','supplier_name','Component appliance supplier',
  'items',jsonb_build_array(jsonb_build_object('item_id',stove,'quantity',3,'bottle_quantity',0,'unit_price',500,'bottle_unit_price',0)));
 purchase:=(public.create_purchase(payload)->>'purchase_id')::uuid;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=purchase;
 perform public.receive_purchase(purchase,rev);
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price) values(t,stove,'retail','package',700);
 result:=public.create_pos_sale('01700000717','Stove component buyer',null,null,'retail',0,0,'Single Unit sale',
  jsonb_build_array(jsonb_build_object('item_id',stove,'type','package','quantity',1,'unit_price',700)),
  p_request_id=>gen_random_uuid(),p_payments=>'[]');
 perform pg_temp.assert((public.get_product_performance('stove')->'totals'->>'cogs')::numeric=500,'Stove COGS uses its Unit FIFO');
 perform public.reverse_sale((result->>'sale_id')::uuid,'Exact Unit restoration','CANCEL',gen_random_uuid());
 select revision into rev from public.purchases where tenant_id=t and purchase_id=purchase;
 perform public.initiate_purchase_cancellation(purchase,rev,'CANCEL',gen_random_uuid());
 perform pg_temp.assert((select unit_quantity=2 and gas_quantity=0 and bottle_quantity=0 from public.items where tenant_id=t and item_id=stove)
  and (app_private.component_inventory_evidence(t,stove)->>'consistent')::boolean,'Received Stove cancellation removes its original Unit acquisition');
 -- New Bottle purchases acquire only their two component costs; transport posts through Cash Register.
 payload:=jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',vehicle,'transport_cost',100,'labour_cost',50,
   'items',jsonb_build_array(jsonb_build_object('item_id',item,'quantity',2,'bottle_quantity',2,'unit_price',700,'bottle_unit_price',150)));
 purchase:=(public.create_purchase(payload)->>'purchase_id')::uuid;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=purchase;
 perform public.dispatch_purchase(purchase,rev);
 perform pg_temp.assert((select count(*)=2 and sum(amount)=0 from public.wallet_transactions where tenant_id=t
   and reference_id in(purchase,(select transit_id from public.transits where tenant_id=t and purchase_id=purchase))
   and type in('purchase_transport_payment','transit_purchase_income')),'Transport has exactly two paired Cash Register legs');
 select revision into rev from public.purchases where tenant_id=t and purchase_id=purchase;
 perform public.receive_purchase(purchase,rev);
 perform pg_temp.assert((app_private.component_inventory_evidence(t,item)->>'consistent')::boolean,'Component invoice, labour and transport reconcile');
 request:=gen_random_uuid();
 result:=public.record_purchase_payment(purchase,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100)),request);
 perform pg_temp.assert(public.record_purchase_payment(purchase,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100)),request)=result,'Supplier payment retains original retry result');
 perform pg_temp.assert((public.get_finance_analysis(jsonb_build_object('from',(now() at time zone 'Asia/Dhaka')::date-1,'to',(now() at time zone 'Asia/Dhaka')::date,'category','all'))->'closing'->>'assets')::numeric
   =(public.get_finance_analysis(jsonb_build_object('from',(now() at time zone 'Asia/Dhaka')::date-1,'to',(now() at time zone 'Asia/Dhaka')::date,'category','all'))->'closing'->>'liabilities')::numeric
    +(public.get_finance_analysis(jsonb_build_object('from',(now() at time zone 'Asia/Dhaka')::date-1,'to',(now() at time zone 'Asia/Dhaka')::date,'category','all'))->'closing'->>'equity')::numeric,
  'Combined canonical journal position balances');
 perform pg_temp.assert(not exists(select 1 from public.accounting_lines where tenant_id=t group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0),'Every posted action balances');
end$$;

insert into auth.users(id,email,is_anonymous)
values('fc071000-0000-4000-8000-000000000002','component-other-owner@example.invalid',false);
select pg_temp.fixture_identity('fc071000-0000-4000-8000-000000000002');
select pg_temp.fixture_business('Foreign component disposable acceptance','Foreign component owner');
set local role authenticated;
select pg_temp.assert((select count(*)=0 from public.items where item_id=(select value from component_security_ids where key='item')),
 'RLS hides foreign component stock');
do $$begin
 begin
  perform public.get_fifo_stock((select value from component_security_ids where key='item'));
  raise exception 'FAIL: Foreign FIFO read accepted';
 exception when insufficient_privilege then null;end;
 begin
  perform 1 from app_private.fifo_layers;
  raise exception 'FAIL: Direct FIFO access accepted';
 exception when insufficient_privilege then null;end;
 begin
  perform app_private.fifo_take(null,null,null,'gas',1);
  raise exception 'FAIL: Direct component issue accepted';
 exception when insufficient_privilege then null;end;
end$$;
reset role;
select pg_temp.fixture_identity('');
set local role anon;
do $$begin
 begin
  perform public.get_fifo_stock((select value from component_security_ids where key='item'));
  raise exception 'FAIL: Anonymous FIFO read accepted';
 exception when insufficient_privilege then null;end;
end$$;
reset role;
