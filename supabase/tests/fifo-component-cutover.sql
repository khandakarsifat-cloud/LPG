-- The runner inserts this purchase under the old writer and receives it under the new writer.
insert into auth.users(id,email,is_anonymous)
values('fc061000-0000-4000-8000-000000000001','fifo-cutover-fixture@example.invalid',false);
select pg_temp.fixture_identity('fc061000-0000-4000-8000-000000000001');
select pg_temp.fixture_business('FIFO cutover disposable acceptance','FIFO cutover owner');
create temp table fifo_cutover_fixture(tenant_id uuid,item_id uuid,purchase_id uuid);

do $$declare
 t uuid:=app_private.current_tenant_id();
 brand uuid; item uuid; plant uuid; driver uuid; vehicle uuid; purchase uuid;
begin
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Cutover Gas') returning brand_id into brand;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,12,'22mm') returning item_id into item;
 insert into public.gas_plants(tenant_id,plant_name,brand_id) values(t,'Cutover plant',brand) returning plant_id into plant;
 insert into public.employee_types(tenant_id,name) values(t,'Driver') on conflict do nothing;
 driver:=(public.save_employee(jsonb_build_object('name','Cutover driver','employee_type_name','Driver',
   'business_unit','truck_business','phones',jsonb_build_array(jsonb_build_object('phone','01700000610','is_primary',true)),
   'terms',jsonb_build_object('effective_from',(now() at time zone 'Asia/Dhaka')::date,'monthly_salary',0,'is_active',true)),
   gen_random_uuid())->>'employee_id')::uuid;
 vehicle:=(public.save_vehicle(jsonb_build_object('name','Cutover vehicle','serial_no','FIFO-CUTOVER','capacity',100,
   'driver_employee_id',driver,'book_value',1000,'funding','capital'),gen_random_uuid())->>'vehicle_id')::uuid;
 perform public.adjust_inventory(jsonb_build_object('item_id',item,'kind','capital','filled_quantity',0,
   'empty_quantity',3,'empty_unit_cost',100,'reason','First opening bottle layer'),gen_random_uuid());
 perform public.adjust_inventory(jsonb_build_object('item_id',item,'kind','capital','filled_quantity',0,
   'empty_quantity',4,'empty_unit_cost',120,'reason','Second opening bottle layer'),gen_random_uuid());
 purchase:=(public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',vehicle,
   'items',jsonb_build_array(jsonb_build_object('item_id',item,'quantity',5,'bottle_quantity',0,
     'unit_price',700,'bottle_unit_price',0))))->>'purchase_id')::uuid;
 perform public.dispatch_purchase(purchase,(select revision from public.purchases where tenant_id=t and purchase_id=purchase));
 insert into fifo_cutover_fixture values(t,item,purchase);
end$$;

-- FIFO CUTOVER BOUNDARY

do $$declare f fifo_cutover_fixture;before_layers jsonb;after_layers jsonb;
begin
 select * into strict f from fifo_cutover_fixture;
 if not (select count(*)=2 and sum(h.quantity)=5 and sum(h.value)=540
   from app_private.fifo_purchase_holdings h join public.inventory_movements d
     on d.tenant_id=h.tenant_id and d.movement_id=h.dispatch_movement_id
   where h.tenant_id=f.tenant_id and d.reference_id=f.purchase_id and h.settled_movement_id is null)
   or not (select bottle_quantity=2 and filled_quantity=0 and empty_quantity=2
     from public.items where tenant_id=f.tenant_id and item_id=f.item_id) then
  raise exception 'Cutover did not retain both open custody slices with exact quantities and cost';
 end if;
 select jsonb_agg(to_jsonb(a) order by layer_id) into before_layers
 from app_private.fifo_component_layers a where tenant_id=f.tenant_id and item_id=f.item_id and component='bottle';
 perform public.receive_purchase(f.purchase_id,
   (select revision from public.purchases where tenant_id=f.tenant_id and purchase_id=f.purchase_id));
 select jsonb_agg(to_jsonb(a) order by layer_id) into after_layers
 from app_private.fifo_component_layers a where tenant_id=f.tenant_id and item_id=f.item_id and component='bottle';
 if before_layers is distinct from after_layers
   or not (select count(*)=1 and sum(quantity)=5 and sum(value)=3500
     from app_private.fifo_component_layers where tenant_id=f.tenant_id and item_id=f.item_id and component='gas')
   or not (select bottle_quantity=7 and filled_quantity=5 and empty_quantity=2
     from public.items where tenant_id=f.tenant_id and item_id=f.item_id)
   or not (select filled_value=4040 and empty_value=240 from public.inventory_costs
     where tenant_id=f.tenant_id and item_id=f.item_id)
   or exists(select 1 from app_private.fifo_purchase_holdings where tenant_id=f.tenant_id and settled_movement_id is null)
   or not app_private.fifo_components_consistent(f.tenant_id,f.item_id) then
  raise exception 'Receipt of migrated custody failed stock, component, or carrying-value reconciliation';
 end if;
end$$;
