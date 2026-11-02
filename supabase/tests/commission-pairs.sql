begin;
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',message;end if;end $$;
insert into auth.users(id,email,is_anonymous) values('fd890000-0000-4000-8000-000000000001','commission-pairs@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','fd890000-0000-4000-8000-000000000001',true);
select public.setup_business('Disposable Package Refill commissions','Commission owner');
reset role;
do $$declare t uuid:=app_private.current_tenant_id();a uuid;b uuid;brand uuid;plant uuid;v uuid;p uuid;pa uuid;current_purchase uuid;
 commission_month date:=(date_trunc('month',now() at time zone 'Asia/Dhaka')-interval '1 month')::date;today date:=(now() at time zone 'Asia/Dhaka')::date;
 r jsonb;body jsonb;k uuid:=gen_random_uuid();before integer;begin
 brand:=pg_temp.fixture_brand(t,'Price basis supplier');plant:=(public.create_gas_plant('Price basis plant',brand,'Dhaka')->>'plant_id')::uuid;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,12,'22mm') returning item_id into a;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,35,'22mm') returning item_id into b;
 v:=(public.save_vehicle(jsonb_build_object('name','Commission pair truck','serial_no','PAIR-01','capacity',100,'book_value',100000,'funding','opening'),gen_random_uuid())->>'vehicle_id')::uuid;perform pg_temp.fixture_vehicle_crew(t,v);
 perform public.adjust_inventory(jsonb_build_object('item_id',a,'kind','opening','filled_quantity',0,'empty_quantity',4,'empty_unit_cost',1500,'date',commission_month,'reason','Original reusable shells A'),gen_random_uuid());
 perform public.adjust_inventory(jsonb_build_object('item_id',b,'kind','opening','filled_quantity',0,'empty_quantity',2,'empty_unit_cost',3500,'date',commission_month,'reason','Original reusable shells B'),gen_random_uuid());
 pa:=(public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',v,'items',jsonb_build_array(
 jsonb_build_object('item_id',a,'type','package','quantity',2,'unit_price',2500,'shell_unit_cost',1500),jsonb_build_object('item_id',a,'type','refill','quantity',4,'unit_price',1000,'empty_dispatched',4),
 jsonb_build_object('item_id',b,'type','package','quantity',1,'unit_price',5000,'shell_unit_cost',3500),jsonb_build_object('item_id',b,'type','refill','quantity',2,'unit_price',2000,'empty_dispatched',2))))->>'purchase_id')::uuid;
 perform public.dispatch_purchase(pa,1,commission_month+1);perform public.receive_purchase(pa,2,commission_month+2);
 current_purchase:=(public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',v,'commission',1800,'items',jsonb_build_array(jsonb_build_object('item_id',a,'type','package','quantity',1,'unit_price',3000,'shell_unit_cost',1500))))->>'purchase_id')::uuid;
 perform public.dispatch_purchase(current_purchase,1,today);perform public.receive_purchase(current_purchase,2,today);
 r:=public.get_monthly_commissions(a,commission_month);
 perform pg_temp.assert((r->'current'->>'package_rate')::numeric=250 and (r->'current'->>'refill_rate')::numeric=100,'9000/18000 invoice value earns 900: Package 250 and Refill 100');
 r:=public.get_monthly_commissions(b,commission_month);
 perform pg_temp.assert((r->'current'->>'package_rate')::numeric=500 and (r->'current'->>'refill_rate')::numeric=200,'Unit prices double rates despite 35/12 weight ratio');
 r:=public.get_monthly_commissions(a,commission_month);before:=(r->>'total')::integer;
 body:=jsonb_build_object('item_id',a,'month',commission_month,'package_rate',300,'refill_rate',80,'expected_revision',(r->'current'->>'revision')::integer);
 perform public.set_monthly_commission(body,k);perform public.set_monthly_commission(body,k);
 r:=public.get_monthly_commissions(a,commission_month);
 perform pg_temp.assert((r->>'total')::integer=before+1 and r->'current'->>'source'='manual' and (r->>'earned')::numeric=920,'Custom pair replaces automatic pair and appends exactly one history row');
 perform pg_temp.assert((select count(*)=1 from public.monthly_commission_rates where tenant_id=t and item_id=a and month=commission_month),'One effective record per product and month');
 perform pg_temp.assert((select sum(l.remaining_value)=4400 from app_private.fifo_layers l join public.inventory_movements m using(tenant_id,movement_id) where l.tenant_id=t and m.reference_id=pa and l.item_id=a and m.reference_type='purchase_receipt_new'),'Package receipt uses 2*(2500-300), with no shell discount');
 perform pg_temp.assert((select sum(l.remaining_value)=9680 from app_private.fifo_layers l join public.inventory_movements m using(tenant_id,movement_id) where l.tenant_id=t and m.reference_id=pa and l.item_id=a and m.reference_type='purchase_receipt_refill'),'Refill receipt uses 4*(1000-80+1500 original shell)');
 -- A current operational quote must replace the older quote everywhere without
 -- rewriting the old acquisition's earned rates or carrying costs.
 r:=public.get_monthly_commissions(a,date_trunc('month',today)::date);
 perform public.set_monthly_commission(jsonb_build_object('item_id',a,'month',date_trunc('month',today)::date,'package_rate',200,'refill_rate',120,'expected_revision',coalesce((r->'current'->>'revision')::integer,0)),gen_random_uuid());
 r:=public.get_product_inventory(a);
 perform pg_temp.assert((r->'commission'->>'package_rate')::numeric=200 and (r->'commission'->>'refill_rate')::numeric=120,'Product summary exposes only the active pair');
 perform pg_temp.assert((select (x->>'commission_per_unit')::numeric=120 and (x->>'new_price')::numeric=880 from jsonb_array_elements(r->'buying_prices')x where x->>'price_type'='refill'),'Older invoice suggestion uses active Refill 120, not receipt-month 80');
 perform pg_temp.assert((select (x->>'commission_per_unit')::numeric=200 and (x->>'new_price')::numeric=2800 from jsonb_array_elements(r->'buying_prices')x where x->>'price_type'='package'),'Package suggestion uses the same active pair');
 perform pg_temp.assert((select sum(l.remaining_value)=9680 from app_private.fifo_layers l join public.inventory_movements m using(tenant_id,movement_id) where l.tenant_id=t and m.reference_id=pa and l.item_id=a and m.reference_type='purchase_receipt_refill'),'Current quote never changes historical receipt-month FIFO costs');
 perform pg_temp.assert((app_private.effective_commission(t,a,(date_trunc('month',today)+interval '1 month')::date)).refill_rate=120,'Calendar rollover carries forward the one active pair');
 select x into r from jsonb_array_elements(r->'buying_prices')x where x->>'price_type'='refill';
 perform public.set_product_buying_price(jsonb_build_object('item_id',a,'price_type','refill','is_manual',true,'price',777,'reason','Operational override','expected',r->>'history_id'),gen_random_uuid());
 r:=public.get_monthly_commissions(a,date_trunc('month',today)::date);
 perform public.set_monthly_commission(jsonb_build_object('item_id',a,'month',date_trunc('month',today)::date,'package_rate',210,'refill_rate',130,'expected_revision',(r->'current'->>'revision')::integer),gen_random_uuid());
 select x into r from jsonb_array_elements(public.get_product_inventory(a)->'buying_prices')x where x->>'price_type'='refill';
 perform pg_temp.assert((r->>'new_price')::numeric=777 and (r->>'automatic_price')::numeric=870,'Active rate change preserves deliberate approximate override but refreshes suggestion');
 body:=jsonb_build_object('item_id',a,'price_type','refill','is_manual',false,'reason','Restore active suggestion','expected',r->>'history_id');k:=gen_random_uuid();
 perform public.set_product_buying_price(body,k);perform public.set_product_buying_price(body,k);
 select x into r from jsonb_array_elements(public.get_product_inventory(a)->'buying_prices')x where x->>'price_type'='refill';
 perform pg_temp.assert((r->>'new_price')::numeric=870 and not (r->>'is_manual')::boolean,'Automatic restore uses the active pair');
 begin perform public.set_product_buying_price(body,gen_random_uuid());raise exception 'FAIL: stale override accepted';exception when others then if sqlerrm not like 'Buying price changed.%' then raise;end if;end;
 select count(*) into before from public.product_buying_price_history where tenant_id=t;
 perform public.get_product_inventory(a);perform public.get_product_inventory(a);
 perform pg_temp.assert((select count(*)=before from public.product_buying_price_history where tenant_id=t),'Live reference reads never append history');
 -- Restore the historical history-count sentinel used below.
 before:=(public.get_monthly_commissions(a,commission_month)->>'total')::integer-1;
 p:=(public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',v,'commission',100,'items',jsonb_build_array(jsonb_build_object('item_id',a,'type','package','quantity',1,'unit_price',3000,'shell_unit_cost',1500))))->>'purchase_id')::uuid;
 perform public.dispatch_purchase(p,1,today);perform public.receive_purchase(p,2,today);
 r:=public.get_monthly_commissions(a,commission_month);perform pg_temp.assert((r->'current'->>'package_rate')::numeric=300 and (r->'current'->>'refill_rate')::numeric=80 and (r->>'total')::integer=before+1,'Subsequent deductions never create a competing automatic pair over custom rates');
 perform pg_temp.assert(not exists(select 1 from public.accounting_lines where tenant_id=t group by journal_id,business_category having sum(amount)<>0),'Commission revaluation preserves each business equation');
end $$;
set constraints all immediate;
select 'PASS: independent invoice-price allocation, distinct Package/Refill rates, one effective pair, manual override history/retry, matching FIFO/shell and buying-price costs';
rollback;
