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
 perform public.adjust_inventory(jsonb_build_object('item_id',j,'kind','capital','filled_quantity',0,'empty_quantity',70,'empty_unit_cost',1200,'reason','Historical owned cylinders'),gen_random_uuid());
 perform pg_temp.assert((select empty_value=84000 from public.inventory_costs where tenant_id=t and item_id=j),'Historical empty value is independent of current price');
 perform public.set_product_buying_price(jsonb_build_object('item_id',total,'price_type','bottle','is_manual',true,'price',2000,'reason','Received-brand operational reference','expected',null),gen_random_uuid());
 body:=jsonb_build_object('plant_id',plant,'vehicle_id',truck,'transport_cost',2600,'labour_cost',1300,'notes','100 Gas + 30 Bottle','items',jsonb_build_array(jsonb_build_object('item_id',j,'quantity',100,'bottle_quantity',30,'unit_price',800,'bottle_unit_price',1600)));
 req:=gen_random_uuid();result:=public.create_purchase(body||jsonb_build_object('request_id',req));pid:=(result->>'purchase_id')::uuid;
 perform pg_temp.assert(public.create_purchase(body||jsonb_build_object('request_id',req))=result,'Purchase replay returns the original operation');
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 select sum(amount) into before_cash from public.accounting_lines where tenant_id=t and account='cash';
 perform public.dispatch_purchase(pid,rev);
 perform pg_temp.assert((select empty_quantity=0 from public.items where tenant_id=t and item_id=j),'100 Gas + 30 Bottle dispatches exactly 70 empties');
 perform pg_temp.assert((select sum(amount)=before_cash from public.accounting_lines where tenant_id=t and account='cash'),'Internal Logistics allocation moves no Cash');
 perform pg_temp.assert((select coalesce(sum(amount),0)=215900 from public.accounting_lines where tenant_id=t and account in ('inventory_lpg','inventory_transit') and business_category='lpg'),'Business inventory includes its internal transport separately');
 perform pg_temp.assert((select sum(consolidated_amount)=213300 from public.accounting_lines where tenant_id=t and account in ('inventory_lpg','inventory_transit')),'Dispatched owned bottles remain an asset alongside the supplier acquisition');
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 perform public.receive_purchase(pid,rev);
 perform pg_temp.assert((select filled_quantity=100 and empty_quantity=0 from public.items where tenant_id=t and item_id=j),'Receipt has 100 filled cylinders; new Bottles are not counted again');
 select * into pool from public.inventory_costs where tenant_id=t and item_id=j;
 perform pg_temp.assert(pool.filled_value=213300,'Receipt external value = 84000 existing bottles + 128000 acquisitions + 1300 labour');
 perform pg_temp.assert((select sum(remaining_internal_value)=2600 from app_private.fifo_layers where tenant_id=t and item_id=j),'Internal acquisition allocation is capitalized exactly once');
 perform pg_temp.assert((select new_price=824.38 from public.product_buying_price_history where tenant_id=t and item_id=j and price_type='gas' order by effective_at desc,entry_no desc limit 1),'Gas current price uses invoice-value overhead allocation');
 perform pg_temp.assert((select new_price=1648.75 from public.product_buying_price_history where tenant_id=t and item_id=j and price_type='bottle' order by effective_at desc,entry_no desc limit 1),'Bottle current price uses its own acquisition allocation');
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price) values(t,j,'retail','refill',1250),(t,j,'retail','package',3000);
 result:=public.create_pos_sale('01700000404','Core test customer',null,null,'retail',0,0,'Two Jamuna, one Jamuna and one Total exchange',jsonb_build_array(
  jsonb_build_object('item_id',j,'type','refill','quantity',2,'unit_price',1250),
  jsonb_build_object('item_id',j,'type','empty_return','quantity',1,'unit_price',0),
  jsonb_build_object('item_id',total,'type','empty_return','quantity',1,'unit_price',0)),p_request_id=>gen_random_uuid(),p_payments=>'[]');
 sid:=(result->>'sale_id')::uuid;
 perform pg_temp.assert((select filled_quantity=98 and empty_quantity=1 from public.items where tenant_id=t and item_id=j),'Jamuna physical state after two refill exchanges');
 perform pg_temp.assert((select filled_quantity=0 and empty_quantity=1 from public.items where tenant_id=t and item_id=total),'Cross-brand receipt is one Total Gas empty');
 perform pg_temp.assert((select empty_value=1648.75 from public.inventory_costs where tenant_id=t and item_id=j),'Same-brand incoming bottle snapshots current price');
 perform pg_temp.assert((select empty_value=2000 from public.inventory_costs where tenant_id=t and item_id=total),'Cross-brand incoming bottle snapshots its own price');
 perform pg_temp.assert((select sum(value)=4016.25 and sum(shell_value)=2400 from app_private.fifo_consumptions x join public.inventory_movements m using(tenant_id,movement_id) where x.tenant_id=t and m.reference_id=sid and m.filled_quantity_change<0),'Outgoing gas and Bottle cost use their actual oldest linked acquisition');
 perform pg_temp.assert((select coalesce(sum(amount),0)=0 from public.accounting_lines where tenant_id=t and account='bottle_receivable' and entity_id=sid),'Both exchanged bottles close the original replacement claim; observed='||(select coalesce(sum(amount),0)::text from public.accounting_lines where tenant_id=t and account='bottle_receivable' and entity_id=sid)||'; source='||(select coalesce(sum((x->>'amount')::numeric),0)::text from app_private.accounting_source_state st cross join lateral jsonb_array_elements(st.lines)x where st.tenant_id=t and x->>'account'='bottle_receivable' and x->>'entity_id'=sid::text));
 perform pg_temp.assert((select sum(amount)=-1248.75 from public.accounting_lines where tenant_id=t and account='bottle_exchange' and entity_id=sid),'Exchange difference is a signed gain without fictitious cash or sales revenue');
 perform pg_temp.assert((select sum(amount)=before_cash from public.accounting_lines where tenant_id=t and account='cash'),'Unpaid sale and exchanges do not create cash');
 perform pg_temp.assert((select -sum(amount)=2500 from public.accounting_lines where tenant_id=t and account='sales_revenue'),'Sales revenue contains only the billed refill sale');
 perform pg_temp.assert((public.get_product_inventory(j)->'weeks'->0) ? 'bought_gas','Inventory weekly acquisition report uses Gas/Bottle components');
 -- Actual pooled wallet transfer is two entries and cannot change business Cash.
 req:=gen_random_uuid();body:=jsonb_build_object('action','transfer','wallet_id',cash,'destination_id',bank,'amount',8000,'reason','Pooled treasury movement');
 perform public.move_wallet_money(body,req);perform public.move_wallet_money(body,req);
 perform pg_temp.assert((select count(*)=2 and sum(amount)=0 and sum(abs(amount))=16000 from public.wallet_transactions where tenant_id=t and operation_id=req),'Exactly one debit and one credit represent transfer principal');
 perform pg_temp.assert((select sum(amount)=before_cash from public.accounting_lines where tenant_id=t and account='cash'),'Treasury transfer has no business Cash or equity effect');
 perform pg_temp.assert((select count(*)=0 from public.accounting_lines l join public.accounting_journals a using(tenant_id,journal_id) where a.source='wallet' and a.source_id in(select transaction_id from public.wallet_transactions where tenant_id=t and operation_id=req)),'No artificial business journals are created for physical treasury transfers');
 perform pg_temp.assert(not exists(select 1 from public.accounting_lines where tenant_id=t group by journal_id,business_category having sum(amount)<>0),'Every journal balances by business');
 perform pg_temp.assert(not exists(select 1 from public.accounting_lines where tenant_id=t group by journal_id having sum(consolidated_amount)<>0),'Every consolidated journal balances');
 perform pg_temp.assert((select sum(balance) from public.wallets where tenant_id=t)=(select sum(amount) from public.accounting_lines where tenant_id=t and account='cash'),'All real wallets reconcile to canonical pooled Cash');
 foreach category in array array['lpg','stove','logistics','all'] loop
  report:=public.get_finance_analysis(jsonb_build_object('from',(now() at time zone 'Asia/Dhaka')::date,'to',(now() at time zone 'Asia/Dhaka')::date,'category',category,'grain','day'));
  perform pg_temp.assert((report->'closing'->>'assets')::numeric=(report->'closing'->>'liabilities')::numeric+(report->'closing'->>'equity')::numeric,'Financial position balances for '||category);
  perform pg_temp.assert(jsonb_array_length(report->'business_positions')=4,'Business tabular positions come from all four canonical scopes');
  if category='all' then
   perform pg_temp.assert((report->'totals'->>'transfers')::numeric=8000,'Transfer reporting is principal, not doubled gross legs');
   perform pg_temp.assert((report->'totals'->>'revenue')::numeric=5100 and (report->'totals'->>'expenses')::numeric=400,'Independent additive revenue includes Logistics transport; LPG expenses contain only consumed transport');
  elsif category='lpg' then
   perform pg_temp.assert((report->'totals'->>'expenses')::numeric=400,'LPG cost includes its actual allocated transport');
  end if;
 end loop;
 select jsonb_agg(jsonb_build_object('layer',layer_id,'quantity',quantity,'value',value,'age',acquired_at) order by layer_id) into original_layers from app_private.fifo_layers where tenant_id=t and item_id=j and component='filled';
 select h.history_id into history_id from public.product_buying_price_history h where h.tenant_id=t and h.item_id=j and h.price_type='bottle' order by effective_at desc,entry_no desc limit 1;
 perform public.set_product_buying_price(jsonb_build_object('item_id',j,'price_type','bottle','is_manual',true,'price',5000,'reason','Later price does not revalue prior stock','expected',history_id),gen_random_uuid());
 perform pg_temp.assert((select empty_value=1648.75 from public.inventory_costs where tenant_id=t and item_id=j),'Manual current-price edit never rewrites received FIFO');
 perform public.reverse_sale(sid,'Original goods and exchange bottles returned','CANCEL',gen_random_uuid());
 perform pg_temp.assert((select filled_quantity=100 and empty_quantity=0 from public.items where tenant_id=t and item_id=j),'Cancellation restores original filled quantities');
 perform pg_temp.assert((select filled_value=213300 from public.inventory_costs where tenant_id=t and item_id=j),'Cancellation restores original Gas and Bottle acquisition values');
 perform pg_temp.assert((public.get_product_inventory(j)->'weeks'->0->>'empty_return')::numeric=0 and (public.get_product_inventory(total)->'weeks'->0->>'empty_return')::numeric=0,'Cancelled sales do not leave empty receipts in weekly product history');
 perform pg_temp.assert((select coalesce(sum(amount),0)=0 from public.accounting_lines where tenant_id=t and account in ('cogs','bottle_exchange')),'Cancelled sale leaves no cost or exchange variance');
 perform pg_temp.assert((select jsonb_agg(jsonb_build_object('layer',layer_id,'quantity',quantity,'value',value,'age',acquired_at) order by layer_id)=original_layers from app_private.fifo_layers where tenant_id=t and item_id=j and component='filled'),'Original layer identities and acquisition ages survive cancellation');
 -- A delayed receipt records the active received-brand price when it arrives.
 result:=public.create_pos_sale('01700000404','Core test customer',null,null,'retail',0,0,'Deferred bottle return',jsonb_build_array(
  jsonb_build_object('item_id',j,'type','refill','quantity',2,'unit_price',1250),
  jsonb_build_object('item_id',j,'type','empty_return','quantity',1,'unit_price',0),
  jsonb_build_object('item_id',total,'type','empty_return','quantity',1,'unit_price',0)),p_customer_id=>(select customer_id from public.sales where tenant_id=t and sale_id=sid),p_request_id=>gen_random_uuid(),p_payments=>'[]',p_bottles=>'{"lines":[]}');sid:=(result->>'sale_id')::uuid;
 perform pg_temp.assert((select sum(amount)=2400 from public.accounting_lines where tenant_id=t and account='bottle_receivable' and entity_id=sid),'Unreturned bottles retain their actual historical asset basis');
 perform public.collect_sale_bottles(sid,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',total,'quantity',1))),gen_random_uuid());
 perform pg_temp.assert((select sum(amount)=1200 from public.accounting_lines where tenant_id=t and account='bottle_receivable' and entity_id=sid),'Partial collection clears only the cumulative proportion of the historical claim');
 perform public.collect_sale_bottles(sid,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',j,'quantity',1))),gen_random_uuid());
 perform pg_temp.assert((select empty_value=5000 from public.inventory_costs where tenant_id=t and item_id=j),'Delayed Jamuna empty acquires the price effective at actual receipt');
 -- Sending that returned bottle to the plant makes cancellation legitimately
 -- unavailable until the original customer batch is restored to local custody.
 result:=public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',truck,'transport_cost',0,'labour_cost',0,'items',jsonb_build_array(jsonb_build_object('item_id',j,'quantity',1,'bottle_quantity',0,'unit_price',900,'bottle_unit_price',0))));
 -- The previous purchase is received; its returned transit is still open for
 -- operating settlement, which does not occupy the vehicle in active custody.
 pid:=(result->>'purchase_id')::uuid;select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 perform public.dispatch_purchase(pid,rev);
 select sum(amount) into before_value from public.accounting_lines where tenant_id=t and account in ('inventory_lpg','inventory_transit');
 begin
  perform public.reverse_sale(sid,'Consumed return must not be substituted','CANCEL',gen_random_uuid());
  raise exception 'FAIL: consumed received bottle cancellation was accepted';
 exception when others then
  if sqlerrm not like 'The original received batch has been consumed%' then raise;end if;
 end;
 perform pg_temp.assert((select sum(amount)=before_value from public.accounting_lines where tenant_id=t and account in ('inventory_lpg','inventory_transit')),'Failed cancellation is atomic across every product and journal');
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 perform public.initiate_purchase_cancellation(pid,rev,'CANCEL',gen_random_uuid());
 perform pg_temp.assert((select empty_value=5000 from public.inventory_costs where tenant_id=t and item_id=j),'Purchase cancellation restores the exact original empty value');
 perform public.reverse_sale(sid,'Original returned batch restored after cancelled dispatch','CANCEL',gen_random_uuid());
 perform pg_temp.assert((select filled_value=213300 from public.inventory_costs where tenant_id=t and item_id=j),'Delayed return and dispatch cancellation preserve original acquisitions');
 begin
  perform public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'items',jsonb_build_array(jsonb_build_object('item_id',j,'quantity',0,'bottle_quantity',1,'unit_price',0,'bottle_unit_price',1000))));
  raise exception 'FAIL: bottle-only purchase accepted';
 exception when others then if sqlerrm not like 'Gas quantity must be positive%' then raise;end if;end;
 perform public.adjust_inventory(jsonb_build_object('item_id',j,'kind','capital','filled_quantity',0,'empty_quantity',5,'empty_unit_cost',1100,'reason','Additional historical owned bottles'),gen_random_uuid());
 select h.history_id into history_id from public.product_buying_price_history h where h.tenant_id=t and h.item_id=j and h.price_type='gas' order by effective_at desc,entry_no desc limit 1;
 perform public.set_product_buying_price(jsonb_build_object('item_id',j,'price_type','gas','is_manual',true,'price',9999,'reason','Temporary operational suggestion','expected',history_id),gen_random_uuid());
 result:=public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',truck,'transport_cost',0,'labour_cost',5,'items',jsonb_build_array(jsonb_build_object('item_id',j,'quantity',5,'bottle_quantity',0,'unit_price',900,'bottle_unit_price',0))));pid:=(result->>'purchase_id')::uuid;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;perform public.dispatch_purchase(pid,rev);
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;perform public.receive_purchase(pid,rev);
 perform pg_temp.assert((select filled_quantity=105 and empty_quantity=0 from public.items where tenant_id=t and item_id=j),'Gas-only purchase refills exactly the owned dispatched bottles');
 perform pg_temp.assert((select filled_value=223305 from public.inventory_costs where tenant_id=t and item_id=j),'Gas-only receipt adds 4505 actual acquisition and retains 5500 owned bottle cost');
 perform pg_temp.assert((select new_price=901 and not is_manual from public.product_buying_price_history where tenant_id=t and item_id=j and price_type='gas' order by effective_at desc,entry_no desc limit 1),'A newer Gas receipt replaces the temporary manual current Gas price');
 perform pg_temp.assert((select new_price=5000 and is_manual from public.product_buying_price_history where tenant_id=t and item_id=j and price_type='bottle' order by effective_at desc,entry_no desc limit 1),'Gas-only receipt leaves current Bottle price untouched');
 result:=public.create_pos_sale('01700000406','Package FIFO customer',null,null,'retail',0,0,'Exhaust the oldest acquisition before using the newer one',jsonb_build_array(jsonb_build_object('item_id',j,'type','package','quantity',101,'unit_price',3000)),p_request_id=>gen_random_uuid(),p_payments=>'[]');sid:=(result->>'sale_id')::uuid;
 perform pg_temp.assert((select sum(value)=215301 and sum(shell_value)=133587.50 from app_private.fifo_consumptions x join public.inventory_movements m using(tenant_id,movement_id) where x.tenant_id=t and m.reference_id=sid and m.filled_quantity_change<0),'Package FIFO exhausts 100 old units then one new unit, using historical Gas and Bottle costs');
 perform pg_temp.assert((select filled_quantity=4 and filled_value=8004 from public.inventory_costs where tenant_id=t and item_id=j),'Remaining actual acquisition is four newer 2001-unit-cost filled cylinders');
 perform public.reverse_sale(sid,'Restore full original package batches','CANCEL',gen_random_uuid());
 perform pg_temp.assert((select filled_quantity=105 and filled_value=223305 from public.inventory_costs where tenant_id=t and item_id=j),'Package return restores the original acquisition layers');
 perform pg_temp.assert(exists(select 1 from jsonb_array_elements(public.get_dashboard_activity(0,30)->'entries')a where a->>'title'='Sale cancelled'),'Dashboard cancellation activity comes from the actual cancellation record');
 result:=public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',truck,'transport_cost',0,'labour_cost',0,'items',jsonb_build_array(jsonb_build_object('item_id',j,'quantity',2,'bottle_quantity',2,'unit_price',700,'bottle_unit_price',1000))));pid:=(result->>'purchase_id')::uuid;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 perform public.dispatch_purchase(pid,rev,(now() at time zone 'Asia/Dhaka')::date-1);
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 perform public.receive_purchase(pid,rev,(now() at time zone 'Asia/Dhaka')::date-1);
 perform pg_temp.assert((select filled_quantity=107 and filled_value=226705 from public.inventory_costs where tenant_id=t and item_id=j),'Backdated acquisition rebuild preserves all returned layers and actual final stock');
 perform pg_temp.assert((select new_price=901 from public.product_buying_price_history where tenant_id=t and item_id=j and price_type='gas' order by effective_at desc,entry_no desc limit 1),'Older receipt cannot replace newer current Gas price');
 perform pg_temp.assert((select new_price=5000 from public.product_buying_price_history where tenant_id=t and item_id=j and price_type='bottle' order by effective_at desc,entry_no desc limit 1),'Older receipt cannot replace newer manual Bottle price');
 perform pg_temp.assert((select coalesce(sum(amount),0)=0 and coalesce(sum(consolidated_amount),0)=0 from public.accounting_lines where tenant_id=t and account in ('cogs','bottle_exchange','bottle_receivable')),'Backdated FIFO replay refreshes cancelled claim and exchange reversals without residual expense or assets');
 perform pg_temp.assert(not app_private.reconcile_record(t,'inventory',j),'Inventory ledger, FIFO and canonical inventory journals reconcile after historical replay');
 select type_id into stove_type from public.stove_product_types where tenant_id=t and is_active order by type_id limit 1;
 result:=public.save_stove_product(jsonb_build_object('name','Two burner acceptance stove','type_id',stove_type),gen_random_uuid());stove:=(result->>'item_id')::uuid;
 result:=public.create_purchase(jsonb_build_object('business_category','stove','supplier_name','Appliance supplier','request_id',gen_random_uuid(),'vehicle_id',truck,'transport_cost',200,'labour_cost',100,'items',jsonb_build_array(jsonb_build_object('item_id',stove,'quantity',3,'bottle_quantity',0,'unit_price',1500,'bottle_unit_price',0))));pid:=(result->>'purchase_id')::uuid;
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;perform public.dispatch_purchase(pid,rev);
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;perform public.receive_purchase(pid,rev);
 perform public.record_purchase_payment(pid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1000)),gen_random_uuid());
 perform pg_temp.assert((select filled_quantity=3 and filled_value=4600 and empty_quantity=0 from public.inventory_costs where tenant_id=t and item_id=stove),'Stove receipt and labour use the same actual acquisition engine without Bottle components');
 perform pg_temp.assert((select payable_amount=4600 and paid_amount=1000 from public.purchases where tenant_id=t and purchase_id=pid),'Stove partial supplier payment preserves its outstanding acquisition liability');
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;
 select sum(balance) into before_cash from public.wallets where tenant_id=t;
 perform public.initiate_purchase_cancellation(pid,rev,'CANCEL',gen_random_uuid());
 perform pg_temp.assert((select sum(balance)=before_cash from public.wallets where tenant_id=t),'Cancelling a prepaid receipt never invents a cash refund');
 perform pg_temp.assert((select filled_quantity=0 and filled_value=0 from public.inventory_costs where tenant_id=t and item_id=stove),'Stove return removes its exact unconsumed acquisition');
 perform pg_temp.assert((select coalesce(sum(amount),0)=0 from public.accounting_lines where tenant_id=t and account='inventory_transit'),'Returned received stock leaves no phantom transport asset in transit');
 select obligation_id into obligation from public.purchase_refund_obligations where tenant_id=t and purchase_id=pid;
 perform public.refund_purchase(pid,obligation,jsonb_build_array(jsonb_build_object('wallet_id',bank,'amount',1000)),gen_random_uuid());
 perform pg_temp.assert((select refund_due=0 and financial_closed_at is not null from public.purchases where tenant_id=t and purchase_id=pid),'An actual supplier refund closes the original cancellation obligation');
 perform public.employee_payment_operation(jsonb_build_object('action','pay','items',jsonb_build_array(jsonb_build_object('employee_id',driver,'kind','bonus','bonus_name','Trip safety bonus','payment_date',(now() at time zone 'Asia/Dhaka')::date,'payments',jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100))))),gen_random_uuid());
 report:=public.get_finance_analysis(jsonb_build_object('from',(now() at time zone 'Asia/Dhaka')::date,'to',(now() at time zone 'Asia/Dhaka')::date,'category','logistics','grain','day'));
 perform pg_temp.assert((report->'closing'->>'cash')::numeric=-100,'Logistics uses the shared wallet without a fictitious business sub-wallet balance');
 perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(report->'closing'->'accounts')a where a->>'account'='cash' and a->>'kind'='liability'),'Negative business Cash is not reclassified as an interbusiness debt or overdraft');
 result:=public.accounting_operation(jsonb_build_object('action','loan_create','amount',3000,'lender','Acceptance lender','wallet_id',bank,'date',(now() at time zone 'Asia/Dhaka')::date,'description','Stove working-capital loan','allocations','{"stove":100}'::jsonb),gen_random_uuid());loan:=(result->>'id')::uuid;
 perform public.accounting_operation(jsonb_build_object('action','loan_repay','loan_id',loan,'amount',500,'wallet_id',bank,'date',(now() at time zone 'Asia/Dhaka')::date,'description','Principal repayment'),gen_random_uuid());
 perform pg_temp.assert((select outstanding=2500 from public.loans where tenant_id=t and loan_id=loan),'Loan principal remains a liability rather than profit or expense');
 result:=public.create_custom_transit(jsonb_build_object('vehicle_id',truck,'fee',1000,'client_name','External service client','destination','Acceptance delivery','description','Completion retry and custody test'),gen_random_uuid());trip:=(result->>'transit_id')::uuid;
 select revision into rev from public.transits where tenant_id=t and transit_id=trip;
 body:='{"driver_cost":50,"helper_cost":0,"oil_cost":30,"others_cost":20,"additional_costs":[]}';
 perform public.transition_transit(trip,'complete',rev,body);
 perform pg_temp.assert((public.transition_transit(trip,'complete',rev,body)->>'already_applied')::boolean,'Exact completion retry is idempotent');
 begin
  perform public.transition_transit(trip,'complete',rev,body||'{"oil_cost":31}'::jsonb);
  raise exception 'FAIL: conflicting completion intent was silently accepted';
 exception when others then if sqlerrm not like 'Transit was already changed with different completion details%' then raise;end if;end;
 perform pg_temp.assert((select status='idle' from public.vehicles where tenant_id=t and vehicle_id=truck),'Completed transit returns the vehicle to Home');
 -- Fault injection recreates a retained closed legacy receivable. Only its
 -- client collection route reopens; closed operating costs remain immutable.
 update public.transits set transport_fee=1500 where tenant_id=t and transit_id=trip;
 perform public.record_operating_payment(jsonb_build_object('transit_id',trip,'kind','client_receipt','payment_date',(now() at time zone 'Asia/Dhaka')::date,'payments',jsonb_build_array(jsonb_build_object('wallet_id',bank,'amount',500))),gen_random_uuid());
 perform pg_temp.assert(app_private.transit_client_paid(t,trip)=1500,'Closed transit retains a normal collection route for an actual outstanding client balance');
 perform pg_temp.assert((select coalesce(sum(amount),0)=0 from public.accounting_lines where tenant_id=t and account='transport_receivable' and entity_id=trip),'Closed transit collection settles its exact receivable once');
 perform pg_temp.assert((select sum(balance) from public.wallets where tenant_id=t)=(select sum(amount) from public.accounting_lines where tenant_id=t and account='cash'),'Supplier, payroll, loan and Logistics payments all reconcile through pooled treasury');
 perform pg_temp.assert(not app_private.reconcile_record(t,'wallet',cash) and not app_private.reconcile_record(t,'wallet',bank),'Each real wallet reconciles to its own ledger, and pooled Cash to journals');
 -- Foundation regression: a consolidation-only journal delta must not vanish.
 -- This isolated assertion uses a fresh source and the whole fixture rolls back.
 req:=gen_random_uuid();
 perform app_private.sync_journal(t,'development_opening',req,(now() at time zone 'Asia/Dhaka')::date,'Isolated consolidation delta regression',jsonb_build_array(
  app_private.accounting_line('equipment',100,'lpg',req),app_private.accounting_line('capital',-100,'lpg')));
 perform app_private.sync_journal(t,'development_opening',req,(now() at time zone 'Asia/Dhaka')::date,'Isolated consolidation delta regression',jsonb_build_array(
  app_private.accounting_line('equipment',100,'lpg',req)||jsonb_build_object('consolidated_amount',80),app_private.accounting_line('capital',-100,'lpg')||jsonb_build_object('consolidated_amount',-80)));
 perform pg_temp.assert((select sum(l.amount)=100 and sum(l.consolidated_amount)=80 from public.accounting_lines l join public.accounting_journals a using(tenant_id,journal_id) where a.tenant_id=t and a.source_id=req and l.account='equipment'),'A zero-business, nonzero-consolidation correction remains in authoritative journals');
 raise notice 'PASS Gas/Bottle purchase, custody, FIFO, 2/1/1 exchange, overhead, current prices, pooled treasury and independent financial checks';
end$$;

do $$declare r jsonb;side text;k text;expected numeric;begin
 r:=public.get_finance_analysis(jsonb_build_object('from',(now() at time zone 'Asia/Dhaka')::date,'to',(now() at time zone 'Asia/Dhaka')::date,'category','all'));
 foreach side in array array['opening','closing'] loop
 foreach k in array array['assets','liabilities','equity','cash','capital','revenue','expenses','withdrawals','other_equity','accumulated_income'] loop
 select sum((p->side->>k)::numeric) into expected from jsonb_array_elements(r->'business_positions')p where p->>'category'<>'all';
 perform pg_temp.assert((r->side->>k)::numeric=expected,'Combined is exactly additive: '||side||'/'||k);
 end loop;end loop;
end $$;
