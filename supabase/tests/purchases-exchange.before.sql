-- Disposable replay only: create plans under the previously deployed workflow.
do $$ begin
  if current_setting('lpg.disposable_replay',true) is distinct from 'on' then
    raise exception 'Exchange compatibility fixtures require a disposable database';
  end if;
end $$;
insert into auth.users(id,email,is_anonymous) values ('ac000000-0000-4000-8000-000000000001','exchange-compatibility@example.invalid',false);
select set_config('request.jwt.claim.sub','ac000000-0000-4000-8000-000000000001',false);
select public.setup_business('Exchange compatibility fixture','Exchange owner');
insert into public.lpg_brands(tenant_id,brand_id,brand_name) values
  (app_private.current_tenant_id(),'ac000000-0000-4000-8000-000000000002','Exchange company');
insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name) values
  (app_private.current_tenant_id(),'ac000000-0000-4000-8000-000000000003','ac000000-0000-4000-8000-000000000002','Exchange plant');
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,filled_quantity,empty_quantity) values
  (app_private.current_tenant_id(),'ac000000-0000-4000-8000-000000000004','ac000000-0000-4000-8000-000000000002','Exchange item',12,5,20);
insert into public.trucks(tenant_id,truck_id,name,serial_no,capacity,size) values
  (app_private.current_tenant_id(),'ac000000-0000-4000-8000-000000000005','Draft truck','Draft truck',100,'medium'),
  (app_private.current_tenant_id(),'ac000000-0000-4000-8000-000000000006','Dispatched truck','Dispatched truck',100,'medium');
create temp table exchange_purchases(kind text,id uuid);
insert into exchange_purchases select 'draft',(public.create_purchase('{"plant_id":"ac000000-0000-4000-8000-000000000003","request_id":"ac100000-0000-4000-8000-000000000001","truck_id":"ac000000-0000-4000-8000-000000000005","items":[{"item_id":"ac000000-0000-4000-8000-000000000004","type":"refill","quantity":4,"empty_dispatched":6,"unit_price":100}]}')->>'purchase_id')::uuid;
insert into exchange_purchases select 'dispatched',(public.create_purchase('{"plant_id":"ac000000-0000-4000-8000-000000000003","request_id":"ac100000-0000-4000-8000-000000000002","truck_id":"ac000000-0000-4000-8000-000000000006","items":[{"item_id":"ac000000-0000-4000-8000-000000000004","type":"refill","quantity":4,"empty_dispatched":6,"unit_price":100}]}')->>'purchase_id')::uuid;
select public.dispatch_purchase(id,1) from exchange_purchases where kind='dispatched';
create temp table exchange_stock_snapshot as select * from public.items;
create temp table exchange_wallet_snapshot as select * from public.wallets;
create temp table exchange_movement_snapshot as select * from public.inventory_movements;
create temp table exchange_transaction_snapshot as select * from public.wallet_transactions;
create temp table exchange_header_snapshot as select * from public.purchases;
create temp table exchange_transit_snapshot as select * from public.transits;
create temp table exchange_lines_snapshot as select * from public.purchase_items;
select set_config('request.jwt.claim.sub','',false);
