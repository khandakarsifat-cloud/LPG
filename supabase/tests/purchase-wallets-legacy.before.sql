-- Disposable migration replay only: seed pre-transition purchases through old RPCs.
insert into auth.users(id,email,is_anonymous) values('f9100000-0000-4000-8000-000000000001','purchase-migration@example.invalid',false);
select set_config('request.jwt.claim.sub','f9100000-0000-4000-8000-000000000001',false);
select public.setup_business('Purchase migration preservation fixture','Migration owner');
insert into public.lpg_brands(tenant_id,brand_id,brand_name) values(app_private.current_tenant_id(),'f9100000-0000-4000-8000-000000000002','Legacy company');
insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name) values(app_private.current_tenant_id(),'f9100000-0000-4000-8000-000000000003','f9100000-0000-4000-8000-000000000002','Legacy plant');
insert into public.trucks(tenant_id,truck_id,name,serial_no,capacity,size) values(app_private.current_tenant_id(),'f9100000-0000-4000-8000-000000000004','Legacy truck','Legacy truck',100,'medium');
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,empty_quantity,filled_quantity) values(app_private.current_tenant_id(),'f9100000-0000-4000-8000-000000000005','f9100000-0000-4000-8000-000000000002','Legacy company',12,10,10);
do $$declare id uuid;begin
 id:=(public.create_purchase('{"plant_id":"f9100000-0000-4000-8000-000000000003","truck_id":"f9100000-0000-4000-8000-000000000004","request_id":"f9100000-0000-4000-8000-000000000006","transport_cost":20,"labour_cost":10,"items":[{"item_id":"f9100000-0000-4000-8000-000000000005","type":"refill","quantity":2,"unit_price":100}]}'::jsonb)->>'purchase_id')::uuid;
 perform public.dispatch_purchase(id,1);perform public.pay_purchase(id,2);perform public.receive_purchase(id,3);
 update public.purchases set legacy_record=true where tenant_id=app_private.current_tenant_id();
end $$;
do $$declare id uuid;begin
 id:=(public.create_purchase('{"plant_id":"f9100000-0000-4000-8000-000000000003","truck_id":"f9100000-0000-4000-8000-000000000004","request_id":"f9100000-0000-4000-8000-000000000007","notes":"Legacy paid transit","transport_cost":20,"labour_cost":10,"items":[{"item_id":"f9100000-0000-4000-8000-000000000005","type":"refill","quantity":1,"unit_price":100}]}'::jsonb)->>'purchase_id')::uuid;
 perform public.dispatch_purchase(id,1);perform public.pay_purchase(id,2);
 update public.purchases set legacy_record=true where tenant_id=app_private.current_tenant_id();
end $$;
insert into public.purchases(tenant_id,purchase_id,plant_id,brand_id,status,subtotal,company_payable,transport_cost,total_cost,transport_funded,notes,legacy_record)
 values(app_private.current_tenant_id(),'f9100000-0000-4000-8000-000000000008','f9100000-0000-4000-8000-000000000003','f9100000-0000-4000-8000-000000000002','in_transit',100,100,10,110,10,'Legacy uncharged funding',true);
insert into public.purchase_items(tenant_id,purchase_id,item_id,type,quantity,billed_quantity,unit_price,line_total)
 values(app_private.current_tenant_id(),'f9100000-0000-4000-8000-000000000008','f9100000-0000-4000-8000-000000000005','package',1,1,100,100);
insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
 select tenant_id,wallet_id,10,'transport_income','f9100000-0000-4000-8000-000000000008','Historical Logistics funding without purchasing debit' from public.wallets where tenant_id=app_private.current_tenant_id() and type='logistics';
create schema purchase_migration_fixture;
create table purchase_migration_fixture.snapshot as select
 (select md5(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text) from public.items i) stock,
 (select md5(jsonb_agg(jsonb_build_array(tenant_id,wallet_id,type,balance,updated_at) order by tenant_id,wallet_id)::text) from public.wallets) wallets,
 (select md5(jsonb_agg(jsonb_build_array(tenant_id,transaction_id,wallet_id,amount,type,reference_id,description,created_at,balance_after) order by tenant_id,transaction_id)::text) from public.wallet_transactions) ledger,
 (select md5(jsonb_agg(to_jsonb(tr) order by tenant_id,transit_id)::text) from public.transits tr) transits,
 (select md5(jsonb_agg(to_jsonb(pi) order by tenant_id,purchase_item_id)::text) from public.purchase_items pi) lines;
