-- Independent rebate expectations on the owned disposable clone only.
create function pg_temp.rebate_assert(ok boolean,message text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',message;end if;end$$;
insert into auth.users(id,email,is_anonymous) values('fc061000-0000-4000-8000-000000000001','rebate-owner@example.invalid',false);
select pg_temp.fixture_identity('fc061000-0000-4000-8000-000000000001');
select pg_temp.fixture_business('Purchase rebate disposable acceptance','Rebate owner');
do $$declare
 t uuid:=app_private.current_tenant_id();brand uuid;product uuid;plant uuid;truck uuid;driver uuid;pid uuid;cancelled uuid;next_id uuid;
 cash uuid;rev integer;result jsonb;body jsonb;req uuid;cost_hash text;price_hash text;layer_hash text;money numeric;credit numeric;category text;r jsonb;full jsonb;
begin
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Rebate Company') returning brand_id into brand;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,12,'22mm') returning item_id into product;
 insert into public.gas_plants(tenant_id,brand_id,plant_name) values(t,brand,'Rebate plant') returning plant_id into plant;
 insert into public.employee_types(tenant_id,name) values(t,'Driver') on conflict do nothing;
 result:=public.save_employee(jsonb_build_object('name','Rebate driver','employee_type_name','Driver','business_unit','truck_business','terms',jsonb_build_object('effective_from',(now() at time zone 'Asia/Dhaka')::date,'monthly_salary',0,'is_active',true),'phones',jsonb_build_array(jsonb_build_object('phone','01700000601','is_primary',true))),gen_random_uuid());driver:=(result->>'employee_id')::uuid;
 result:=public.save_vehicle(jsonb_build_object('name','Rebate truck','serial_no','REBATE-601','capacity',100,'driver_employee_id',driver,'book_value',1000,'funding','capital'),gen_random_uuid());truck:=(result->>'vehicle_id')::uuid;
 select wallet_id into cash from public.wallets where tenant_id=t and type='cash';
 perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',cash,'amount',100000,'classification','capital','business','lpg','reason','Rebate fixture original funds'),gen_random_uuid());
 body:=jsonb_build_object('plant_id',plant,'vehicle_id',truck,'transport_cost',600,'labour_cost',300,'rebate_amount',5000,'items',jsonb_build_array(jsonb_build_object('item_id',product,'quantity',10,'bottle_quantity',10,'unit_price',1000,'bottle_unit_price',2000)));
 result:=public.create_purchase(body||jsonb_build_object('request_id',gen_random_uuid()));pid:=(result->>'purchase_id')::uuid;
 perform pg_temp.rebate_assert(not exists(select 1 from app_private.purchase_rebate_events where tenant_id=t),'Draft rebate creates no income, credit or payment');
 select revision into rev from public.purchases where purchase_id=pid;
 perform public.dispatch_purchase(pid,rev);
 perform pg_temp.rebate_assert((select subtotal=30000 and payable_amount=30300 and total_cost=30900 and paid_amount=0 and payment_status='partial' from public.purchases where purchase_id=pid),'Gross costs preserved; rebate is settlement, not wallet payment');
 select revision into rev from public.purchases where purchase_id=pid;perform public.receive_purchase(pid,rev);
 perform pg_temp.rebate_assert((select sum(amount)=-25300 from public.accounting_lines where tenant_id=t and account='supplier_payable'),'Receipt invoice and rebate leave exactly 25300 supplier liability');
 perform pg_temp.rebate_assert((select -sum(amount)=5000 from public.accounting_lines where tenant_id=t and account='other_income'),'Confirmed rebate income is recognized exactly once');
 perform pg_temp.rebate_assert((select gas_value+bottle_value=30300 from public.inventory_costs where tenant_id=t and item_id=product),'Actual gross acquisition and labour, never rebate, determine FIFO');
 perform public.record_purchase_payment(pid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',10000)),gen_random_uuid());
 perform pg_temp.rebate_assert((public.get_purchase_settlement(pid)->>'due')::numeric=15300,'Partial wallet payment and rebate settle different portions');
 begin
  perform public.record_purchase_payment(pid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',15300.01)),gen_random_uuid());
  raise exception 'FAIL: cash overpayment accepted';
 exception when others then if sqlerrm<>'Payments exceed the remaining purchase balance' then raise;end if;end;
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price) values(t,product,'retail','package',5000);
 result:=public.create_pos_sale('01700000602','Rebate buyer',null,null,'retail',0,0,'Gross historical COGS',jsonb_build_array(jsonb_build_object('item_id',product,'type','package','quantity',1,'unit_price',5000)),p_request_id=>gen_random_uuid(),p_payments=>'[]');
 select md5(coalesce(jsonb_agg(to_jsonb(x) order by layer_id)::text,'')) into layer_hash from app_private.fifo_layers x where x.tenant_id=t;
 select md5(coalesce(jsonb_agg(to_jsonb(x) order by history_id)::text,'')) into price_hash from public.product_buying_price_history x where x.tenant_id=t;
 select md5(coalesce(jsonb_agg(to_jsonb(x) order by purchase_item_id)::text,'')) into cost_hash from public.purchase_items x where x.tenant_id=t;
 select balance into money from public.wallets where wallet_id=cash;
 select revision into rev from public.purchases where purchase_id=pid;req:=gen_random_uuid();body:=jsonb_build_object('amount',4000,'revision',rev);
 result:=public.set_purchase_rebate(pid,body,req);
 perform pg_temp.rebate_assert(public.set_purchase_rebate(pid,body,req)=result,'Rebate response-loss retry returns the original result once');
 begin
  perform public.set_purchase_rebate(pid,body||'{"amount":3999}',req);raise exception 'FAIL: changed rebate retry accepted';
 exception when others then if sqlerrm<>'Request ID already used with different details' then raise;end if;end;
 perform pg_temp.rebate_assert((public.get_purchase_settlement(pid)->>'due')::numeric=16300,'A rebate correction changes the remaining supplier balance before completion');
 select revision into rev from public.purchases where purchase_id=pid;
 begin
  perform public.set_purchase_rebate(pid,jsonb_build_object('amount',20300.01,'revision',rev),gen_random_uuid());raise exception 'FAIL: rebate over-settlement accepted';
 exception when others then if sqlerrm<>'Commission rebate and wallet payments exceed the purchase balance' then raise;end if;end;
 perform public.set_purchase_rebate(pid,jsonb_build_object('amount',5000,'revision',rev),gen_random_uuid());
 perform pg_temp.rebate_assert((select balance=money from public.wallets where wallet_id=cash),'Rebate edits create no cash movement');
 perform pg_temp.rebate_assert((select md5(coalesce(jsonb_agg(to_jsonb(x) order by layer_id)::text,''))=layer_hash from app_private.fifo_layers x where x.tenant_id=t),'Rebate correction preserves every historical FIFO layer');
 perform pg_temp.rebate_assert((select md5(coalesce(jsonb_agg(to_jsonb(x) order by history_id)::text,''))=price_hash from public.product_buying_price_history x where x.tenant_id=t),'Rebate correction preserves current references and immutable price history');
 perform pg_temp.rebate_assert((select md5(coalesce(jsonb_agg(to_jsonb(x) order by purchase_item_id)::text,''))=cost_hash from public.purchase_items x where x.tenant_id=t),'Rebate edits preserve purchase unit prices and gross component amounts');
 perform public.record_purchase_payment(pid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',15300)),gen_random_uuid());
 perform pg_temp.rebate_assert((select paid_amount=25300 and payment_status='paid' from public.purchases where purchase_id=pid),'Rebate plus actual cash fully settles the gross bill');
 select revision into rev from public.purchases where purchase_id=pid;
 begin
  perform public.set_purchase_rebate(pid,jsonb_build_object('amount',4000,'revision',rev),gen_random_uuid());raise exception 'FAIL: completed rebate changed';
 exception when others then if sqlerrm<>'Completed purchase commission rebate is locked' then raise;end if;end;
 perform pg_temp.rebate_assert(public.set_purchase_rebate(pid,body,req)=result,'Original successful rebate retry remains recoverable after completion');
 perform pg_temp.rebate_assert(not (public.get_purchase_settlement(pid)->>'can_rebate')::boolean,'Completed purchase exposes rebate as locked');
 select balance into money from public.wallets where wallet_id=cash;
 r:=public.get_finance_analysis(jsonb_build_object('from',(clock_timestamp() at time zone 'Asia/Dhaka')::date,'to',(clock_timestamp() at time zone 'Asia/Dhaka')::date,'category','all'));
 perform pg_temp.rebate_assert((r->'closing'->>'cash')::numeric=74700 and (r->'closing'->>'revenue')::numeric=10600 and (r->'closing'->>'expenses')::numeric=3090,'Independent consolidated cash, sales plus rebate income and historical COGS');
 perform pg_temp.rebate_assert((r->'closing'->>'assets')::numeric=108510 and (r->'closing'->>'liabilities')::numeric=0,'Independent supplies, cash, receivable and supplier position');
 -- An unreceived LPG order never recognizes an invoice or earns a new rebate.
 body:=jsonb_build_object('plant_id',plant,'vehicle_id',truck,'rebate_amount',3000,'items',jsonb_build_array(jsonb_build_object('item_id',product,'quantity',5,'bottle_quantity',5,'unit_price',1000,'bottle_unit_price',2000)));
 result:=public.create_purchase(body||jsonb_build_object('request_id',gen_random_uuid()));cancelled:=(result->>'purchase_id')::uuid;
 select revision into rev from public.purchases where purchase_id=cancelled;perform public.dispatch_purchase(cancelled,rev);
 perform public.record_purchase_payment(cancelled,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',2000)),gen_random_uuid());
 select revision into rev from public.purchases where purchase_id=cancelled;perform public.initiate_purchase_cancellation(cancelled,rev,'CANCEL',gen_random_uuid());
 perform pg_temp.rebate_assert((public.get_purchase_settlement(cancelled)->>'company_credit')::numeric=0 and (public.get_purchase_settlement(cancelled)->>'refund_due')::numeric=2000,'Unreceived cancellation creates no rebate credit and refunds only actual payments');
 select obligation_id into req from public.purchase_refund_obligations where purchase_id=cancelled;
 perform public.refund_purchase(cancelled,req,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',2000)),gen_random_uuid());
 perform pg_temp.rebate_assert((select balance=money from public.wallets where wallet_id=cash),'Cash refund excludes the noncash rebate');
 result:=public.create_purchase(body||jsonb_build_object('request_id',gen_random_uuid(),'rebate_amount',4000));next_id:=(result->>'purchase_id')::uuid;
 select revision into rev from public.purchases where purchase_id=next_id;perform public.dispatch_purchase(next_id,rev);
 perform pg_temp.rebate_assert(not exists(select 1 from app_private.purchase_rebate_events where purchase_id=next_id),'Dispatch does not recognize a new invoice rebate');
 select revision into rev from public.purchases where purchase_id=next_id;perform public.receive_purchase(next_id,rev);
 perform pg_temp.rebate_assert((select sum(income_delta)=4000 from app_private.purchase_rebate_events where purchase_id=next_id),'Receipt recognizes the actual new rebate with no invented credit');
 perform pg_temp.rebate_assert((public.get_purchase_settlement(next_id)->>'company_credit')::numeric=0,'No unused company credit is fabricated');
 for category in select unnest(array['lpg','stove','logistics','all']) loop
  r:=public.get_finance_analysis(jsonb_build_object('from',(now() at time zone 'Asia/Dhaka')::date,'to',(now() at time zone 'Asia/Dhaka')::date,'grain','day','category',category));
  perform pg_temp.rebate_assert((r->'closing'->>'assets')::numeric=(r->'closing'->>'liabilities')::numeric+(r->'closing'->>'equity')::numeric,'Each business and consolidated equation remains exact');
 end loop;
 perform pg_temp.rebate_assert(not exists(select 1 from public.accounting_lines where tenant_id=t group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0),'Every real journal balances in both dimensions');
 perform pg_temp.rebate_assert(app_private.financial_source_link(t,'purchase_rebate',pid)->>'record_kind'='purchase','Every rebate journal line links to its purchase, including pooled credit');
 perform pg_temp.rebate_assert(not has_table_privilege('authenticated','app_private.purchase_rebate_events','SELECT') and not has_function_privilege('anon','public.set_purchase_rebate(uuid,jsonb,uuid)','EXECUTE'),'Private rebate evidence and public RPC grants preserve access boundaries');
end $$;
