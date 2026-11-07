-- Executed in a disposable, freshly reset clone after the new migration.
-- The runner rolls the entire schema and fixture transaction back.
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',message;end if;end$$;
insert into auth.users(id,email,is_anonymous) values('fc040000-0000-4000-8000-000000000001','core-overhaul-rehearsal@example.invalid',false);
select pg_temp.fixture_identity('fc040000-0000-4000-8000-000000000001');
select pg_temp.fixture_business('LPG core overhaul disposable acceptance','Component fixture owner');

do $$declare
 t uuid:=app_private.current_tenant_id();j uuid;total uuid;jbrand uuid;tbrand uuid;plant uuid;truck uuid;driver uuid;pid uuid;sid uuid;
 cash uuid;bank uuid;req uuid;body jsonb;before_value numeric;before_cash numeric;result jsonb;pool public.inventory_costs;rev integer;report jsonb;category text;original_layers jsonb;history_id uuid;stove uuid;stove_type uuid;trip uuid;loan uuid;obligation uuid;
begin
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Jamuna') returning brand_id into jbrand;
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Total Gas') returning brand_id into tbrand;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,jbrand,12,'22mm') returning item_id into j;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,tbrand,12,'22mm') returning item_id into total;
 insert into public.gas_plants(tenant_id,plant_name,brand_id) values(t,'Component test plant',jbrand) returning plant_id into plant;
 insert into public.employee_types(tenant_id,name) values(t,'Driver') on conflict do nothing;
 result:=public.save_employee(jsonb_build_object('name','Component fixture Driver','employee_type_name','Driver','business_unit','truck_business','phones',jsonb_build_array(jsonb_build_object('phone','01700000405','is_primary',true)),'terms',jsonb_build_object('effective_from',(now() at time zone 'Asia/Dhaka')::date,'monthly_salary',0,'is_active',true)),gen_random_uuid());
 driver:=(result->>'employee_id')::uuid;
 result:=public.save_vehicle(jsonb_build_object('name','Component test truck','serial_no','CORE-REHEARSAL','capacity',500,'driver_employee_id',driver,'book_value',500000,'funding','capital'),gen_random_uuid());truck:=(result->>'vehicle_id')::uuid;
 select wallet_id into cash from public.wallets where tenant_id=t and type='cash';
 select wallet_id into bank from public.wallets where tenant_id=t and type='dealership';
 perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',cash,'business','lpg','classification','capital','amount',200000,'reason','Initial business funds'),gen_random_uuid());
 perform public.adjust_inventory(jsonb_build_object('item_id',j,'kind','capital','bottle_quantity',70,'bottle_unit_cost',1200,'reason','Historical owned cylinders'),gen_random_uuid());
 perform pg_temp.assert((select bottle_value=84000 from public.inventory_costs where tenant_id=t and item_id=j),'Historical empty value is independent of current price');
 perform public.set_product_buying_price(jsonb_build_object('item_id',total,'price_type','bottle','is_manual',true,'price',2000,'reason','Received-brand operational reference','expected',null),gen_random_uuid());

 select count(*) into before_value from public.accounting_journals where tenant_id=t;
 result:=public.create_purchase(jsonb_build_object('plant_id',plant,'vehicle_id',truck,'transport_cost',500,'labour_cost',200,'items','[]'::jsonb,'request_id',gen_random_uuid()));
 pid:=(result->>'purchase_id')::uuid;
 perform pg_temp.assert((select count(*)=before_value from public.accounting_journals where tenant_id=t),'Draft has no financial posting');
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 body:=jsonb_build_object('items',jsonb_build_array(jsonb_build_object('item_id',j,'quantity',100,'bottle_quantity',30,'unit_price',800,'bottle_unit_price',1600)));
 perform public.update_purchase(pid,body,rev);
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 select count(*) into before_value from app_private.fifo_layers where tenant_id=t;
 perform public.dispatch_purchase(pid,rev);
 perform pg_temp.assert((select count(*)=before_value from app_private.fifo_layers where tenant_id=t),'Dispatch preserves original Gas/Bottle acquisitions');
 perform pg_temp.assert((select sum(amount)=-500 from public.wallet_transactions where tenant_id=t and reference_id=pid and type='purchase_transport_payment'),'Dispatch pays transport once');
 perform pg_temp.assert((select coalesce(sum(amount),0)=0 from public.accounting_lines where tenant_id=t and account='supplier_payable'),'Dispatch recognizes no supplier invoice');
 perform pg_temp.assert((select coalesce(sum(amount),0)=0 from public.accounting_lines where tenant_id=t and account='business_allocation_equity'),'Cash transport uses no capital');
 perform pg_temp.assert((select sum(amount)=-500 from public.accounting_lines where tenant_id=t and account='cash' and business_category='logistics') is false,'Logistics receives transport cash');
 perform pg_temp.assert(not app_private.reconcile_record(t,'inventory',j),'Held bottles reconcile without a journal reclassification');
 select transit_id into trip from public.transits where tenant_id=t and purchase_id=pid;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 perform public.receive_purchase(pid,rev);
 perform pg_temp.assert((select sum(amount)=-128200 from public.accounting_lines where tenant_id=t and account='supplier_payable'),'Receipt recognizes actual supplier cost and labour');
 perform pg_temp.assert(not app_private.reconcile_record(t,'inventory',j),'Receipt reconciles old shells and new Gas/Bottle costs');
 perform pg_temp.assert((select sum(amount)=500 from public.accounting_lines where tenant_id=t and account='cash' and business_category='logistics'),'Logistics cash is separate');
 perform pg_temp.assert((select sum(balance)=200000 from public.wallets where tenant_id=t),'Paired entries preserve physical Cash Register total');

 select revision into rev from public.transits where tenant_id=t and transit_id=trip;
 perform public.transition_transit(trip,'complete',rev,'{"driver_cost":0,"helper_cost":0,"oil_cost":0,"others_cost":0,"additional_costs":[]}'::jsonb);
 result:=public.create_purchase(jsonb_build_object('plant_id',plant,'vehicle_id',truck,'transport_cost',300,'labour_cost',0,'request_id',gen_random_uuid(),
 'items',jsonb_build_array(jsonb_build_object('item_id',j,'quantity',2,'bottle_quantity',2,'unit_price',800,'bottle_unit_price',1600))));
 pid:=(result->>'purchase_id')::uuid;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;perform public.dispatch_purchase(pid,rev);
 select transit_id into trip from public.transits where tenant_id=t and purchase_id=pid;
 perform public.record_purchase_payment(pid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1000)),gen_random_uuid());
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 perform public.initiate_purchase_cancellation(pid,rev,'CANCEL',gen_random_uuid());
 req:=gen_random_uuid();result:=public.refund_purchase_transport(trip,100,req);
 perform pg_temp.assert(public.refund_purchase_transport(trip,100,req)=result,'Transport refund retry is idempotent');
 perform pg_temp.assert((result->>'remaining')::numeric=200,'Partial refund retains remaining transport amount');
 begin
  perform public.refund_purchase_transport(trip,201,gen_random_uuid());raise exception 'FAIL: excessive refund accepted';
 exception when others then if sqlerrm not like 'Refund exceeds%' then raise;end if;end;
 perform public.refund_purchase_transport(trip,200,gen_random_uuid());
 perform pg_temp.assert((public.get_purchase_transport(trip)->>'remaining')::numeric=0,'Transport can be refunded completely in parts');
 perform pg_temp.assert((select sum(amount)=300 from public.wallet_transactions where tenant_id=t and reference_id=pid and type='purchase_transport_refund'),'Buyer refund has purchase source');
 perform pg_temp.assert((select sum(amount)=-300 from public.wallet_transactions where tenant_id=t and reference_id=trip and type='transit_purchase_refund'),'Logistics refund has transit source');
 perform pg_temp.assert((select coalesce(sum(amount),0)=0 from public.accounting_lines where tenant_id=t and account='operating_expense'),'Full transport refund reverses cancellation cost');
 perform pg_temp.assert(not exists(select 1 from public.accounting_lines where tenant_id=t group by journal_id having sum(amount)<>0),'All actions balance');
end $$;
