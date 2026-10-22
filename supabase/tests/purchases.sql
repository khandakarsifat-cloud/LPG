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
      'receive_purchase','pay_purchase','cancel_purchase','save_transit_costs','transition_transit','list_purchases','get_purchase_activity','list_transits','update_transit_costs'))
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
declare id uuid; id2 uuid; tr uuid; p public.purchases; lines jsonb; err_detail text; before_dw numeric; before_lw numeric; n integer;
begin
  id:=(public.create_purchase('{"plant_id":"dd000000-0000-4000-8000-000000000001","request_id":"ab000000-0000-4000-8000-000000000001"}')->>'purchase_id')::uuid;
  perform pg_temp.check_purchase((pg_temp.purchase_header(id)).status='created','plant-only draft');
  perform pg_temp.check_purchase((public.create_purchase('{"plant_id":"dd000000-0000-4000-8000-000000000001","request_id":"ab000000-0000-4000-8000-000000000001"}')->>'purchase_id')::uuid=id,'creation retry returns original purchase');
  perform pg_temp.purchase_fails('select public.create_purchase(''{"plant_id":"dd000000-0000-4000-8000-000000000001","request_id":"ab000000-0000-4000-8000-000000000001","transport_cost":1}'')','different purchase details');
  perform pg_temp.purchase_fails(format('select public.receive_purchase(%L,1)',id),'In Transit');
  perform pg_temp.purchase_fails(format('select public.pay_purchase(%L,1)',id),'after dispatch');
  begin
    perform public.update_purchase(id,'{"items":[{"item_id":"ff000000-0000-4000-8000-000000000001","type":"refill","quantity":11,"unit_price":100},{"item_id":"ff000000-0000-4000-8000-000000000003","type":"refill","quantity":2,"unit_price":100}]}',1);
    raise exception 'FAIL: shortages accepted';
  exception when others then
    if sqlerrm<>'Not enough empty cylinders' then raise; end if;
    get stacked diagnostics err_detail=pg_exception_detail;
    perform pg_temp.check_purchase(jsonb_array_length(err_detail::jsonb)=2,'all stock shortages reported');
  end;
  perform pg_temp.check_purchase((pg_temp.purchase_header(id)).revision=1 and jsonb_array_length(pg_temp.purchase_lines(id))=0,'failed save is atomic');
  lines:='[{"item_id":"ff000000-0000-4000-8000-000000000001","type":"refill","quantity":4,"unit_price":100},{"item_id":"ff000000-0000-4000-8000-000000000001","type":"package","quantity":2,"unit_price":200}]';
  perform public.update_purchase(id,jsonb_build_object('truck_id','ee000000-0000-4000-8000-000000000001','items',lines,'commission',50,'transport_cost',20,'labour_cost',10),1);
  perform pg_temp.check_purchase((pg_temp.purchase_header(id)).total_cost=780,'financial breakdown');
  perform pg_temp.purchase_fails(format('select public.dispatch_purchase(%L,1)',id),'changed');
  perform public.dispatch_purchase(id,2);
  perform public.dispatch_purchase(id,2);
  select transit_id into tr from public.transits where purchase_id=id;
  perform pg_temp.check_purchase((select empty_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001')=6,'dispatch deducts empties once');
  perform pg_temp.check_purchase((select balance from public.wallets where type='dealership')=-20 and (select balance from public.wallets where type='logistics')=20,'dispatch transfers transport fee once');
  perform pg_temp.check_purchase((select client_name='Company A' and destination='Plant A' from public.transits where transit_id=tr),'purchase transit identity filled automatically');
  perform pg_temp.purchase_fails(format('select public.transition_transit(%L,''complete'',1)',tr),'follow the purchase');
  perform public.save_transit_costs(tr,'{"driver_cost":5,"helper_cost":3,"oil_cost":2,"others_cost":1,"additional_costs":[{"name":"Toll","amount":4}]}',1);
  perform public.pay_purchase(id,3);
  perform public.pay_purchase(id,3);
  perform pg_temp.check_purchase((select balance from public.wallets where type='dealership')=-780 and (select balance from public.wallets where type='logistics')=20,'payment counts dispatched transport once');
  perform public.receive_purchase(id,4);
  perform public.receive_purchase(id,4);
  perform pg_temp.check_purchase((select filled_quantity from public.items where item_id='ff000000-0000-4000-8000-000000000001')=11,'expected refills and new cylinders received once');
  perform pg_temp.check_purchase((select status='completed' and closed_at is null from public.transits where transit_id=tr),'receipt completes transit without closing costs');
  perform pg_temp.check_purchase((select balance from public.wallets where type='logistics')=20,'receipt does not post operating costs');
  perform pg_temp.check_purchase((select status='idle' from public.trucks where truck_id='ee000000-0000-4000-8000-000000000001'),'truck released on receipt');
  perform public.save_transit_costs(tr,'{"driver_cost":6,"helper_cost":3,"oil_cost":2,"others_cost":1,"additional_costs":[{"name":"Toll","amount":4}]}',3);
  perform pg_temp.purchase_fails(format('select public.transition_transit(%L,''close'',3)',tr),'changed');
  perform public.transition_transit(tr,'close',4);
  perform public.transition_transit(tr,'close',4);
  perform pg_temp.check_purchase((select balance from public.wallets where type='logistics')=4,'closure deducts edited costs once');
  perform pg_temp.purchase_fails(format('select public.save_transit_costs(%L,''{"driver_cost":0,"helper_cost":0,"oil_cost":0,"others_cost":0}'',5)',tr),'locked');
  -- Cancellation after receipt/payment/closure reverses stock and purchase money, retaining spent transit costs.
  perform public.cancel_purchase(id,5);
  perform public.cancel_purchase(id,5);
  perform pg_temp.check_purchase((select filled_quantity=5 and empty_quantity=10 from public.items where item_id='ff000000-0000-4000-8000-000000000001'),'received cancellation reverses stock once');
  perform pg_temp.check_purchase((select balance from public.wallets where type='dealership')=0 and (select balance from public.wallets where type='logistics')=-16,'purchase cancellation refunds recorded payments and retains operating expense');
  -- Draft / dispatched unpaid / dispatched paid / received unpaid cancellation.
  for n in 1..4 loop
    id2:=(public.create_purchase(jsonb_build_object('plant_id','dd000000-0000-4000-8000-000000000001','truck_id','ee000000-0000-4000-8000-000000000001',
      'request_id',gen_random_uuid(),'transport_cost',20,'labour_cost',10,'items',lines))->>'purchase_id')::uuid;
    if n>1 then perform public.dispatch_purchase(id2,1); end if;
    if n=3 then perform public.pay_purchase(id2,2); end if;
    if n=4 then perform public.receive_purchase(id2,2); end if;
    perform public.cancel_purchase(id2,(pg_temp.purchase_header(id2)).revision);
    perform pg_temp.check_purchase((select balance from public.wallets where type='dealership')=0 and (select balance from public.wallets where type='logistics')=-16,'cancellation stage refund');
    perform pg_temp.check_purchase((select filled_quantity=5 and empty_quantity=10 from public.items where item_id='ff000000-0000-4000-8000-000000000001'),'cancellation stage stock');
  end loop;
  -- Receive first, adjust unpaid prices/transport, then pay.
  id2:=(public.create_purchase(jsonb_build_object('plant_id','dd000000-0000-4000-8000-000000000001','truck_id','ee000000-0000-4000-8000-000000000001',
    'request_id',gen_random_uuid(),'transport_cost',20,'labour_cost',10,'items',lines))->>'purchase_id')::uuid;
  perform public.dispatch_purchase(id2,1);
  perform public.receive_purchase(id2,2);
  perform public.update_purchase(id2,'{"transport_cost":30,"commission":50}',3);
  perform public.pay_purchase(id2,4);
  perform pg_temp.check_purchase((select balance from public.wallets where type='dealership')=-790 and (select balance from public.wallets where type='logistics')=14,'transport edits transfer difference; payment does not double-charge');
  update purchase_test_context set purchase_id=id2;
  -- Custom workflow: fee collected, costs saved, complete frees truck, close deducts costs.
  tr:=(public.create_custom_transit('{"truck_id":"ee000000-0000-4000-8000-000000000001","fee":100,"client_name":"Client A","destination":"Dhaka","description":"Delivery"}')->>'transit_id')::uuid;
  perform pg_temp.purchase_fails('select public.create_custom_transit(''{"truck_id":"ee000000-0000-4000-8000-000000000001","fee":1,"client_name":"Other"}'')','idle truck');
  perform public.save_transit_costs(tr,'{"driver_cost":5,"helper_cost":3,"oil_cost":2,"others_cost":1,"additional_costs":[{"name":"Toll","amount":4}]}',1);
  perform pg_temp.purchase_fails(format('select public.transition_transit(%L,''close'',2)',tr),'Complete');
  perform public.transition_transit(tr,'complete',2);
  perform pg_temp.check_purchase((select status='idle' from public.trucks where truck_id='ee000000-0000-4000-8000-000000000001'),'custom completion frees truck');
  -- Reuse the truck before closing the old trip; closing must not change the new allocation.
  id:=(public.create_custom_transit('{"truck_id":"ee000000-0000-4000-8000-000000000001","fee":50,"client_name":"Client B"}')->>'transit_id')::uuid;
  perform public.save_transit_costs(tr,'{"driver_cost":6,"helper_cost":3,"oil_cost":2,"others_cost":1,"additional_costs":[]}',3);
  perform public.transition_transit(tr,'close',4);
  perform pg_temp.check_purchase((select status='going' from public.trucks where truck_id='ee000000-0000-4000-8000-000000000001'),'closing old trip preserves new truck allocation');
  before_lw:=(select balance from public.wallets where type='logistics');
  perform public.transition_transit(id,'cancel',1);
  perform public.transition_transit(id,'cancel',1);
  perform pg_temp.check_purchase((select balance from public.wallets where type='logistics')=before_lw-50,'custom cancellation refunds client once');
  perform public.transition_transit(id,'close',2);
  perform pg_temp.purchase_fails('select public.create_custom_transit(''{"truck_id":"ee000000-0000-4000-8000-000000000001","fee":0,"client_name":" "}'')','Client name');
  perform pg_temp.purchase_fails('select public.create_custom_transit(''{"truck_id":"ee000000-0000-4000-8000-000000000001","fee":-1,"client_name":"C"}'')','Amounts');
end $$;
-- Sold/used received stock blocks cancellation atomically.
reset role;
update public.items set filled_quantity=0 where tenant_id=(select tenant_a from purchase_test_context) and item_id='ff000000-0000-4000-8000-000000000001';
set local role authenticated;
select pg_temp.purchase_fails(format('select public.cancel_purchase(%L,5)',purchase_id),'no longer available') from purchase_test_context;
select pg_temp.check_purchase((select status='received' from public.list_purchases() p(value) cross join lateral jsonb_populate_record(null::public.purchases,p.value) h where h.purchase_id=(select purchase_id from purchase_test_context)),'failed cancellation retains purchase');
-- A reused ID from another tenant cannot operate on this tenant's purchase/transit.
select set_config('request.jwt.claim.sub','bb000000-0000-4000-8000-000000000001',true);
select pg_temp.purchase_fails(format('select public.cancel_purchase(%L,1)',purchase_id),'not found') from purchase_test_context;
select set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000002',true);
select pg_temp.purchase_fails(format('select public.cancel_purchase(%L,1)',purchase_id),'Permission denied') from purchase_test_context;
select pg_temp.purchase_fails('select public.create_custom_transit(''{"client_name":"Denied"}'')','Permission denied');
reset role;
select 'PASS: purchase/transit workflow, all shortages, receipt defaults, staged cancellation, funding, refunds, cost closure, retries, truck reuse and tenant/capability boundaries';
rollback;
