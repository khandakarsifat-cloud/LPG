-- Real capability/tenant gates and workflow RPCs. All fixtures roll back.
begin;
set local row_security=on;
create function pg_temp.check_purchase(ok boolean,label text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'FAIL: %',label; end if; end $$;
create function pg_temp.purchase_fails(statement text, expected text) returns void language plpgsql as $$
begin
  begin execute statement;
  exception when others then
    if position(expected in sqlerrm)>0 then return; end if;
    raise exception 'FAIL: expected %, got %',expected,sqlerrm;
  end;
  raise exception 'FAIL: invalid request succeeded: %',statement;
end $$;
create function pg_temp.purchase_header(id uuid) returns public.purchases language sql security definer set search_path='' as $$
  select p from public.purchases p where p.tenant_id=app_private.current_tenant_id() and p.purchase_id=id
$$;
create function pg_temp.purchase_lines(id uuid) returns jsonb language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(pi) order by pi.type),'[]') from public.purchase_items pi
    where pi.tenant_id=app_private.current_tenant_id() and pi.purchase_id=id
$$;
grant execute on function pg_temp.check_purchase(boolean,text),pg_temp.purchase_fails(text,text),
  pg_temp.purchase_header(uuid),pg_temp.purchase_lines(uuid) to authenticated;
select pg_temp.check_purchase(not exists(
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='app_private' and p.proname in ('purchase_activity_immutable','purchase_money','purchase_integer',
    'recalculate_purchase','save_purchase_lines','guard_purchase_transit','guard_truck_idle','guard_purchase_company')
    or n.nspname='public' and p.proname in ('create_purchase','update_purchase','dispatch_purchase',
      'receive_purchase','pay_purchase','list_purchases','get_purchase_activity','list_transits','update_transit_costs'))
    and pg_get_userbyid(p.proowner)<>'postgres'),'purchase helpers and RPCs share the existing application owner');
create temp table purchase_test_context(tenant_a uuid,tenant_b uuid,purchase_id uuid);
grant select,insert,update on purchase_test_context to authenticated;
insert into auth.users(id,email,is_anonymous) values
 ('aa000000-0000-4000-8000-000000000001','purchase-owner-a@example.invalid',false),
 ('bb000000-0000-4000-8000-000000000001','purchase-owner-b@example.invalid',false),
 ('aa000000-0000-4000-8000-000000000002','purchase-viewer@example.invalid',false),
 ('aa000000-0000-4000-8000-000000000003','purchase-operator@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000001',true);
insert into purchase_test_context(tenant_a) select (public.setup_business('Purchase tests A','Owner A')->>'tenant_id')::uuid;
select set_config('request.jwt.claim.sub','bb000000-0000-4000-8000-000000000001',true);
update purchase_test_context set tenant_b=(public.setup_business('Purchase tests B','Owner B')->>'tenant_id')::uuid;
reset role;
select set_config('request.jwt.claim.sub','',true);

insert into public.lpg_brands(tenant_id,brand_id,brand_name)
select t,'cc000000-0000-4000-8000-000000000001',name from purchase_test_context
  cross join lateral(values(tenant_a,'Company A'),(tenant_b,'Company B')) v(t,name);
insert into public.lpg_brands(tenant_id,brand_id,brand_name)
select tenant_a,'cc000000-0000-4000-8000-000000000002','Other company' from purchase_test_context;
insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name)
select t,'dd000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',name from purchase_test_context
  cross join lateral(values(tenant_a,'Plant A'),(tenant_b,'Plant B')) v(t,name);
insert into public.gas_plants(tenant_id,plant_id,plant_name)
select tenant_a,'dd000000-0000-4000-8000-000000000002','Unassigned plant' from purchase_test_context;
insert into public.trucks(tenant_id,truck_id,name,serial_no,capacity,size)
select t,'ee000000-0000-4000-8000-000000000001',name,name,100,'medium' from purchase_test_context
  cross join lateral(values(tenant_a,'Truck A'),(tenant_b,'Truck B')) v(t,name);
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,empty_quantity,filled_quantity)
select t,'ff000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',name,12,10,5 from purchase_test_context
  cross join lateral(values(tenant_a,'Item A'),(tenant_b,'Item B')) v(t,name);
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,empty_quantity)
select tenant_a,'ff000000-0000-4000-8000-000000000002','cc000000-0000-4000-8000-000000000002','Wrong company',12,10 from purchase_test_context;
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,empty_quantity)
select tenant_a,'ff000000-0000-4000-8000-000000000003','cc000000-0000-4000-8000-000000000001','Empty stock SKU',25,0 from purchase_test_context;
insert into public.user_profiles(user_id,tenant_id,email)
select u.id,c.tenant_a,u.email from auth.users u cross join purchase_test_context c
where u.id in ('aa000000-0000-4000-8000-000000000002','aa000000-0000-4000-8000-000000000003');
insert into public.roles(tenant_id,role_id,name) select tenant_a,'aa000000-0000-4000-8000-000000000002','Purchase viewer' from purchase_test_context;
insert into public.roles(tenant_id,role_id,name) select tenant_a,'aa000000-0000-4000-8000-000000000003','Purchase operator' from purchase_test_context;
insert into public.role_permissions(tenant_id,role_id,permission_id)
select tenant_a,'aa000000-0000-4000-8000-000000000002'::uuid,'purchases:view' from purchase_test_context
union all select tenant_a,'aa000000-0000-4000-8000-000000000003'::uuid,'purchases:manage' from purchase_test_context;
insert into public.user_roles(tenant_id,user_id,role_id)
select tenant_a,id,id from purchase_test_context cross join lateral(values
 ('aa000000-0000-4000-8000-000000000002'::uuid),('aa000000-0000-4000-8000-000000000003'::uuid)) v(id);

set local role authenticated;
select set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000001',true);
do $$
declare id uuid; id2 uuid; payload jsonb; lines jsonb; receipt jsonb; p public.purchases; wallet_before numeric; inventory_before integer; count_before integer; transit uuid;
begin
  payload := '{"plant_id":"dd000000-0000-4000-8000-000000000001","request_id":"aa100000-0000-4000-8000-000000000001"}';
  id := (public.create_purchase(payload)->>'purchase_id')::uuid;
  perform pg_temp.check_purchase(id=(public.create_purchase(payload)->>'purchase_id')::uuid,'creation retry is idempotent');
  p := pg_temp.purchase_header(id);
  perform pg_temp.check_purchase(p.status='created' and p.payment_status='unpaid' and p.truck_id is null and p.brand_id='cc000000-0000-4000-8000-000000000001','plant-only creation derives company');
  perform pg_temp.check_purchase((select count(*) from public.inventory_movements)=0 and (select count(*) from public.transits)=0,'creation has no inventory or shipment effects');
  perform pg_temp.purchase_fails(format('select public.pay_purchase(%L,1)',id),'after dispatch');
  perform pg_temp.purchase_fails(format('select public.receive_purchase(%L,''[]'',null,1)',id),'In Transit');
  perform pg_temp.purchase_fails(format('select public.dispatch_purchase(%L,1)',id),'idle truck');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"plant_id":"dd000000-0000-4000-8000-000000000002"}'',1)',id),'cannot change');
  perform pg_temp.purchase_fails('select public.create_purchase(''{"plant_id":"dd000000-0000-4000-8000-000000000002","request_id":"aa100000-0000-4000-8000-000000000002"}'')','active plant');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"items":[{"item_id":"ff000000-0000-4000-8000-000000000002","type":"refill","quantity":1,"empty_dispatched":1,"unit_price":100}]}'',1)',id),'plant company');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"items":[{"item_id":"ff000000-0000-4000-8000-000000000001","type":"refill","quantity":1.5,"empty_dispatched":1,"unit_price":100}]}'',1)',id),'whole nonnegative');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"commission":1}'',1)',id),'subtotal');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"transport_cost":"NaN"}'',1)',id),'finite');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"labour_cost":1.001}'',1)',id),'decimal');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"items":[{"item_id":"ff000000-0000-4000-8000-000000000001","type":"refill","quantity":4,"empty_dispatched":6,"unit_price":100}]}'',1)',id),'one empty cylinder per refill');
  lines := '[{"item_id":"ff000000-0000-4000-8000-000000000001","type":"refill","quantity":4,"unit_price":100},
    {"item_id":"ff000000-0000-4000-8000-000000000001","type":"package","quantity":2,"empty_dispatched":0,"unit_price":200}]';
  perform public.update_purchase(id,jsonb_build_object('truck_id','ee000000-0000-4000-8000-000000000001','items',lines,'commission',50,'transport_cost',20,'labour_cost',10),1);
  p := pg_temp.purchase_header(id);
  perform pg_temp.check_purchase(p.subtotal=800 and p.company_payable=750 and p.total_cost=780,'commission separates company payable from logistics');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"notes":"stale"}'',1)',id),'Reload');
  -- Validate duplicate lines and all-or-nothing saving.
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,%L,2)',id,jsonb_build_object('items',lines||lines)),'Duplicate');
  perform pg_temp.check_purchase(jsonb_array_length(pg_temp.purchase_lines(id))=2,'failed line replacement rolls back');
  wallet_before := coalesce((select balance from public.wallets where type='dealership'),0);
  perform public.dispatch_purchase(id,2);
  perform public.dispatch_purchase(id,2);
  p := pg_temp.purchase_header(id);
  perform pg_temp.check_purchase(p.status='in_transit' and p.revision=3 and p.dispatched_at is not null,'dispatch transition and retry');
  perform pg_temp.check_purchase((select empty_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001')=6
    and (select filled_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001')=5,'dispatch deducts one empty per expected refill, once');
  perform pg_temp.check_purchase((select count(*) from public.inventory_movements where reference_id=id)=1,'dispatch movement posted exactly once');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"items":[]}'',3)',id),'locked');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"truck_id":null}'',3)',id),'locked');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,%L,3)',id,jsonb_build_object('items',jsonb_set(pg_temp.purchase_lines(id),'{0,quantity}','9'))),'locked');
  perform pg_temp.purchase_fails('select public.update_gas_plant(''dd000000-0000-4000-8000-000000000001'',p_brand_id=>''cc000000-0000-4000-8000-000000000002'')','cannot change company');
  perform pg_temp.purchase_fails('select public.update_truck(''ee000000-0000-4000-8000-000000000001'',p_status=>''idle'')','Receive');
  perform pg_temp.purchase_fails('select public.create_custom_transit(''ee000000-0000-4000-8000-000000000001'',10,''collision'')','active transit');
  select transit_id into transit from public.transits where purchase_id=id;
  perform pg_temp.purchase_fails(format('select public.update_transit_costs(%L,0,0,0,''[]'',''completed'')',transit),'receiving');
  perform public.update_transit_costs(transit,5,3,2,'[]','active');
  p := pg_temp.purchase_header(id);
  -- Payment before return does not complete inventory or release the truck.
  perform public.pay_purchase(id,p.revision);
  perform public.pay_purchase(id,p.revision);
  p := pg_temp.purchase_header(id);
  perform pg_temp.check_purchase(p.payment_status='paid' and p.status='in_transit' and p.total_cost=780,'payment independent of return');
  perform pg_temp.check_purchase((select balance from public.wallets where type='dealership')=wallet_before-780,'full payment debits once');
  perform pg_temp.check_purchase((select balance from public.wallets where type='logistics')=20,'transport fee credited at payment');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"commission":0}'',%s)',id,p.revision),'locked');
  perform public.update_purchase(id,'{"notes":"Truck at plant"}',p.revision);
  p := pg_temp.purchase_header(id);
  receipt := (select jsonb_agg(jsonb_build_object('purchase_item_id',x->>'purchase_item_id','received_quantity',case when x->>'type'='refill' then 3 else 4 end)) from jsonb_array_elements(pg_temp.purchase_lines(id)) x);
  perform pg_temp.purchase_fails(format('select public.receive_purchase(%L,%L,null,%s)',id,receipt,p.revision),'discrepancy');
  perform public.receive_purchase(id,receipt,'One fewer refill; two extra new cylinders',p.revision);
  perform public.receive_purchase(id,receipt,'Retry',p.revision);
  perform public.pay_purchase(id,p.revision);
  p := pg_temp.purchase_header(id);
  perform pg_temp.check_purchase(p.status='received' and p.payment_status='paid' and p.total_cost=780,'prepaid receipt preserves settled total');
  perform pg_temp.check_purchase((select filled_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001')=12
    and (select empty_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001')=6,'receipt adds actual new/refills only');
  perform pg_temp.check_purchase((select count(*) from public.inventory_movements where reference_id=id)=3,'distinct referenced new/refill movements');
  perform pg_temp.check_purchase((select status from public.trucks where truck_id='ee000000-0000-4000-8000-000000000001')='idle'
    and (select status from public.transits where transit_id=transit)='completed','receipt finalizes transit and releases truck');
  perform pg_temp.check_purchase((select balance from public.wallets where type='logistics')=10,'saved operating costs posted once on return');
  perform pg_temp.purchase_fails(format('select public.update_purchase(%L,''{"notes":"late edit"}'',%s)',id,p.revision),'completed');
  perform pg_temp.purchase_fails(format('select public.receive_purchase(%L,%L,null,%s)',id,jsonb_set(receipt,'{0,received_quantity}','9'),p.revision),'different quantities');
  perform pg_temp.purchase_fails(format('select public.update_transit_costs(%L,0,0,0,''[]'',''active'')',transit),'finalized');
  perform pg_temp.check_purchase((select count(*) from public.get_purchase_activity(id))=7,'activity captures responsible actions without retry duplicates');
  -- Short delivery before payment changes billing to actual quantities.
  payload := jsonb_build_object('plant_id','dd000000-0000-4000-8000-000000000001','request_id',gen_random_uuid(),
    'truck_id','ee000000-0000-4000-8000-000000000001','items',jsonb_build_array(jsonb_build_object(
    'item_id','ff000000-0000-4000-8000-000000000001','type','refill','quantity',7,'empty_dispatched',7,'unit_price',100)));
  id2 := (public.create_purchase(payload)->>'purchase_id')::uuid;
  count_before := (select count(*) from public.inventory_movements);
  perform pg_temp.purchase_fails(format('select public.dispatch_purchase(%L,1)',id2),'Insufficient');
  perform pg_temp.check_purchase((pg_temp.purchase_header(id2)).status='created' and (select count(*) from public.inventory_movements)=count_before,'insufficient-stock dispatch is atomic');
  lines := jsonb_set(jsonb_set(payload->'items','{0,empty_dispatched}','3'),'{0,quantity}','3');
  perform public.update_purchase(id2,jsonb_build_object('items',lines,'commission',50),1);
  perform public.dispatch_purchase(id2,2);
  receipt := jsonb_build_array(jsonb_build_object('purchase_item_id',pg_temp.purchase_lines(id2)->0->>'purchase_item_id','received_quantity',2));
  perform public.receive_purchase(id2,receipt,'Short one refill',3);
  p := pg_temp.purchase_header(id2);
  perform pg_temp.check_purchase(p.status='received' and p.payment_status='unpaid' and p.subtotal=200 and p.company_payable=150,'actual quantity billed before payment');
  lines := pg_temp.purchase_lines(id2);
  perform public.update_purchase(id2,jsonb_build_object('items',jsonb_set(lines,'{0,unit_price}','120')),p.revision);
  p := pg_temp.purchase_header(id2);
  perform pg_temp.check_purchase(p.subtotal=240,'received unpaid unit price editing uses actual billed quantities');
  perform public.update_purchase(id2,'{"commission":20,"transport_cost":10,"labour_cost":5,"notes":"Invoice checked"}',p.revision);
  p := pg_temp.purchase_header(id2);
  perform pg_temp.check_purchase(p.total_cost=235 and p.company_payable=220,'received unpaid financial editing');
  perform public.pay_purchase(id2,p.revision);
  -- New-only purchase: dispatch needs no outgoing empties; zero actual receipt valid.
  payload := jsonb_build_object('plant_id','dd000000-0000-4000-8000-000000000001','request_id',gen_random_uuid(),
    'truck_id','ee000000-0000-4000-8000-000000000001','items','[{"item_id":"ff000000-0000-4000-8000-000000000001","type":"package","quantity":1,"empty_dispatched":0,"unit_price":200}]'::jsonb);
  id2 := (public.create_purchase(payload)->>'purchase_id')::uuid;
  inventory_before := (select empty_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001');
  perform public.dispatch_purchase(id2,1);
  perform pg_temp.check_purchase((select empty_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001')=inventory_before,'new-only dispatch has no stock deduction');
  receipt := jsonb_build_array(jsonb_build_object('purchase_item_id',pg_temp.purchase_lines(id2)->0->>'purchase_item_id','received_quantity',0));
  perform public.receive_purchase(id2,receipt,'No cylinders delivered',2);
  perform public.pay_purchase(id2,3);
  perform pg_temp.check_purchase((pg_temp.purchase_header(id2)).total_cost=0,'zero delivery settles zero bill');
  -- The first SKU movement must roll back if a later SKU has insufficient stock.
  payload := jsonb_build_object('plant_id','dd000000-0000-4000-8000-000000000001','request_id',gen_random_uuid(),
    'truck_id','ee000000-0000-4000-8000-000000000001','items','[
    {"item_id":"ff000000-0000-4000-8000-000000000001","type":"refill","quantity":1,"empty_dispatched":1,"unit_price":100},
    {"item_id":"ff000000-0000-4000-8000-000000000003","type":"refill","quantity":1,"empty_dispatched":1,"unit_price":100}]'::jsonb);
  id2 := (public.create_purchase(payload)->>'purchase_id')::uuid;
  inventory_before := (select empty_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001');
  count_before := (select count(*) from public.inventory_movements);
  perform pg_temp.purchase_fails(format('select public.dispatch_purchase(%L,1)',id2),'Insufficient');
  perform pg_temp.check_purchase((select empty_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001')=inventory_before
    and (select count(*) from public.inventory_movements)=count_before and (pg_temp.purchase_header(id2)).status='created','multiple-SKU dispatch rollback');
  update purchase_test_context set purchase_id=id;
end $$;

-- Reused entity UUIDs still isolate complete reads and mutations.
select set_config('request.jwt.claim.sub','bb000000-0000-4000-8000-000000000001',true);
select pg_temp.check_purchase((select count(*) from public.list_purchases())=0,'cross-tenant list isolation');
select pg_temp.purchase_fails(format('select public.pay_purchase(%L,1)',purchase_id),'not found') from purchase_test_context;
select pg_temp.purchase_fails(format('select public.receive_purchase(%L,''[]'',null,1)',purchase_id),'not found') from purchase_test_context;
select pg_temp.check_purchase((select count(*) from public.get_purchase_activity(purchase_id))=0,'cross-tenant activity isolation') from purchase_test_context;
select pg_temp.check_purchase((select empty_quantity=10 and filled_quantity=5 from public.items where item_id='ff000000-0000-4000-8000-000000000001'),'other tenant stock unchanged');

select set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000002',true);
select pg_temp.check_purchase((select count(*) from public.list_purchases())=4,'read-only capability can inspect purchases');
select pg_temp.purchase_fails('select public.create_purchase(''{}'')','Permission denied');
select pg_temp.purchase_fails(format('select public.update_purchase(%L,''{}'',1)',purchase_id),'Permission denied') from purchase_test_context;
select pg_temp.purchase_fails(format('select public.dispatch_purchase(%L,1)',purchase_id),'Permission denied') from purchase_test_context;
select pg_temp.purchase_fails(format('select public.receive_purchase(%L,''[]'',null,1)',purchase_id),'Permission denied') from purchase_test_context;
select pg_temp.purchase_fails(format('select public.pay_purchase(%L,1)',purchase_id),'Permission denied') from purchase_test_context;

-- purchases:manage alone authorizes internal stock/payment, without manual
-- inventory, logistics or finance management capabilities.
select set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000003',true);
do $$
declare id uuid; lines jsonb;
begin
  id := (public.create_purchase('{"plant_id":"dd000000-0000-4000-8000-000000000001","request_id":"aa100000-0000-4000-8000-000000000005","truck_id":"ee000000-0000-4000-8000-000000000001","items":[{"item_id":"ff000000-0000-4000-8000-000000000001","type":"package","quantity":1,"empty_dispatched":0,"unit_price":200}]}')->>'purchase_id')::uuid;
  perform public.dispatch_purchase(id,1);
  perform public.pay_purchase(id,2);
  lines := jsonb_build_array(jsonb_build_object('purchase_item_id',pg_temp.purchase_lines(id)->0->>'purchase_item_id','received_quantity',1));
  perform public.receive_purchase(id,lines,'',3);
  perform pg_temp.purchase_fails('update public.purchases set commission=0','permission denied');
  perform pg_temp.purchase_fails('insert into public.inventory_movements(tenant_id,item_id,movement_type) values (null,null,''purchase'')','permission denied');
  perform pg_temp.purchase_fails('select app_private.purchase_money(1)','permission denied');
end $$;
reset role;
select pg_temp.check_purchase(not has_function_privilege('anon','public.pay_purchase(uuid,integer)','execute'),'anonymous execution revoked');
select pg_temp.check_purchase(not has_table_privilege('authenticated','public.purchase_activity','insert'),'activity writes private');
select 'PASS: purchase lifecycle, atomic failures, idempotency, company rules, permissions, billing and inventory';
rollback;
