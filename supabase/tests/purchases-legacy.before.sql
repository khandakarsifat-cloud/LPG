-- ONLY the disposable replay runner executes this pre-migration fixture.
do $$ begin
  if current_setting('lpg.disposable_replay',true) is distinct from 'on' then
    raise exception 'Historical fixtures require a disposable replay database';
  end if;
end $$;
insert into auth.users(id,email,is_anonymous) values ('ab000000-0000-4000-8000-000000000001','legacy-purchase@example.invalid',false);
select set_config('request.jwt.claim.sub','ab000000-0000-4000-8000-000000000001',false);
select public.setup_business('Historical purchase fixture','Legacy owner');
insert into public.lpg_brands(tenant_id,brand_id,brand_name) values
 (app_private.current_tenant_id(),'ab000000-0000-4000-8000-000000000002','Legacy company');
insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name) values
 (app_private.current_tenant_id(),'ab000000-0000-4000-8000-000000000003','ab000000-0000-4000-8000-000000000002','Legacy plant');
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,filled_quantity,empty_quantity) values
 (app_private.current_tenant_id(),'ab000000-0000-4000-8000-000000000004','ab000000-0000-4000-8000-000000000002','Legacy item',12,5,20);
insert into public.trucks(tenant_id,truck_id,name,serial_no,capacity,size) values
 (app_private.current_tenant_id(),'ab000000-0000-4000-8000-000000000005','Legacy truck','Legacy truck',100,'medium');
create temp table legacy_purchases(kind text,id uuid);
insert into legacy_purchases select 'received',(public.create_purchase('ab000000-0000-4000-8000-000000000005','ab000000-0000-4000-8000-000000000003',20,10,'Old received',
 '[{"item_id":"ab000000-0000-4000-8000-000000000004","type":"refill","quantity":2,"unit_price":100}]')->>'purchase_id')::uuid;
select public.complete_purchase(id) from legacy_purchases;
insert into legacy_purchases select 'in_transit',(public.create_purchase('ab000000-0000-4000-8000-000000000005','ab000000-0000-4000-8000-000000000003',30,5,'Old shipment',
 '[{"item_id":"ab000000-0000-4000-8000-000000000004","type":"refill","quantity":3,"unit_price":100}]')->>'purchase_id')::uuid;
create temp table legacy_stock_snapshot as select * from public.items;
create temp table legacy_wallet_snapshot as select * from public.wallets;
create temp table legacy_movement_snapshot as select * from public.inventory_movements;
create temp table legacy_transaction_snapshot as select * from public.wallet_transactions;
select set_config('request.jwt.claim.sub','',false);
