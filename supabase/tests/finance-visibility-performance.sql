-- Real authenticated roles; source fixtures roll back in the isolated clone.
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',message;end if;end$$;
grant execute on function pg_temp.assert(boolean,text) to authenticated;
create temp table visibility_fixture(key text,value uuid);
grant select on visibility_fixture to authenticated;
insert into auth.users(id,email,is_anonymous) values
 ('fa050000-0000-4000-8000-000000000001','visibility-owner@example.invalid',false),
 ('fa050000-0000-4000-8000-000000000002','visibility-staff@example.invalid',false);
select pg_temp.fixture_identity('fa050000-0000-4000-8000-000000000001');
insert into visibility_fixture select 'tenant',(pg_temp.fixture_business('Finance visibility disposable acceptance','Finance owner')->>'tenant_id')::uuid;
do $$declare t uuid:=app_private.current_tenant_id();b uuid;i uuid;plant uuid;truck uuid;pid uuid;driver uuid;rev integer;result jsonb;ft uuid;begin
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Jamuna') returning brand_id into b;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,b,12,'22mm') returning item_id into i;
 insert into visibility_fixture values('item',i);
 insert into public.gas_plants(tenant_id,brand_id,plant_name) values(t,b,'Performance test plant') returning plant_id into plant;
 driver:=(public.save_employee(jsonb_build_object('name','Performance Driver','employee_type_name','Driver','business_unit','truck_business','phones',jsonb_build_array(jsonb_build_object('phone','01790000055','is_primary',true)),'terms',jsonb_build_object('effective_from',current_date,'monthly_salary',0,'is_active',true)),gen_random_uuid())->>'employee_id')::uuid;
 truck:=(public.save_vehicle(jsonb_build_object('name','Performance truck','serial_no','PERF-01','capacity',100,'driver_employee_id',driver,'book_value',10000,'funding','capital'),gen_random_uuid())->>'vehicle_id')::uuid;
 perform public.adjust_inventory(jsonb_build_object('item_id',i,'kind','capital','filled_quantity',0,'empty_quantity',70,'empty_unit_cost',1200,'reason','Historical original bottles'),gen_random_uuid());
 pid:=(public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',truck,'transport_cost',2600,'labour_cost',1300,'items',jsonb_build_array(jsonb_build_object('item_id',i,'quantity',100,'bottle_quantity',30,'unit_price',800,'bottle_unit_price',1600))))->>'purchase_id')::uuid;
 perform pg_temp.assert((public.get_product_performance('lpg')->'totals'->>'bought')::numeric=0,'Created orders are not received purchases');
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;perform public.dispatch_purchase(pid,rev);
 perform pg_temp.assert((public.get_product_performance('lpg')->'totals'->>'bought')::numeric=0,'Transit is not received stock');
 select revision into rev from public.purchases where tenant_id=t and purchase_id=pid;perform public.receive_purchase(pid,rev);
 result:=public.get_product_performance('lpg');
 perform pg_temp.assert((select sum((x->>'bought')::numeric) from jsonb_array_elements(result->'rows')x where x->>'type'='refill')=70 and (select sum((x->>'bought')::numeric) from jsonb_array_elements(result->'rows')x where x->>'type'='package')=30,'100 Gas and 30 Bottles report as 70 Refills and 30 Packages');
 result:=public.get_lpg_fifo_stock(i);perform pg_temp.assert(result->'layers'->0->'package_margin'='null'::jsonb,'Missing prices never create zero-price margins');
 result:=public.get_fifo_stock(i,'retail','all',0);perform pg_temp.assert(result->'layers'->0->'refill_margin'='null'::jsonb and result->'layers'->0->'package_margin'='null'::jsonb,'Unified missing selling references never fabricate margins');
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price) values(t,i,'retail','refill',1250),(t,i,'retail','package',3000);
 result:=public.get_lpg_fifo_stock(i);
 perform pg_temp.assert((result->'summary'->>'filled')::integer=100 and (result->'summary'->>'empty')::integer=0,'Component rows do not double physical inventory');
 perform pg_temp.assert((result->'summary'->>'carrying_value')::numeric=215900,'FIFO business value includes historical bottles, acquisition, labour and internal transport once');
 perform pg_temp.assert((result->'summary'->>'gas_value')::numeric+(result->'summary'->>'bottle_value')::numeric=215900,'Separate components reconcile to actual carrying value');
 perform pg_temp.assert((result->'layers'->0->>'bottle_acquired_at')::timestamptz<(result->'layers'->0->>'acquired_at')::timestamptz,'Reused shell retains original acquisition chronology');
 perform pg_temp.assert(abs((result->'layers'->0->>'gas_unit_cost')::numeric-824.38)<0.01,'Gas projected COGS uses its actual historical component allocation');
 perform pg_temp.assert(abs((result->'layers'->0->>'package_margin')::numeric-(3000-(result->'layers'->0->>'carrying_value')::numeric/(result->'layers'->0->>'remaining')::numeric))<0.0001,'Package margin includes linked Gas and Bottle');
 result:=public.get_fifo_stock(i,'retail','all',0);
 perform pg_temp.assert((result->>'total')::integer=2,'Purchase rows remain distinct even when Gas unit costs match');
 perform pg_temp.assert(result->'layers'->0->>'bottle_origin'='owned_reused' and result->'layers'->1->>'bottle_origin'='purchased','Report distinguishes original owned bottles from new bottle acquisitions');
 perform pg_temp.assert((result->'layers'->0->>'bottle_acquired_at')::timestamptz<(result->'layers'->0->>'acquired_at')::timestamptz,'Owned Bottle age is preserved independently of new Gas receipt');
 perform pg_temp.assert((result->'summary'->>'carrying_value')::numeric=215900,'Unified report preserves original carrying value');
 perform pg_temp.assert((result->'layers'->0->>'refill_margin')::numeric>0,'Unified report includes projected Gas margin');
 result:=public.get_fifo_stock(i,'wholesale','filled',0);perform pg_temp.assert(result->'prices'->0->>'customer_tier'='retail' and result->'layers'->0->'package_margin'<>'null'::jsonb,'Unified wholesale projections explicitly use retail fallback');
 result:=public.get_lpg_fifo_stock(i,'wholesale');perform pg_temp.assert(result->'prices'->0->>'customer_tier'='retail' and result->'layers'->0->'package_margin'<>'null'::jsonb,'Wholesale margin follows POS retail fallback with explicit source tier');
 insert into public.user_profiles(tenant_id,user_id,email,full_name) values(t,'fa050000-0000-4000-8000-000000000002','visibility-staff@example.invalid','Restricted staff');
 insert into public.user_roles(tenant_id,user_id,role_id) select t,'fa050000-0000-4000-8000-000000000002',role_id from public.roles where tenant_id=t and name='MANAGER';
 insert into visibility_fixture select 'cash',wallet_id from public.wallets where tenant_id=t and type='cash';
 insert into visibility_fixture select 'bank',wallet_id from public.wallets where tenant_id=t and type='dealership';
 insert into app_private.user_wallet_access select t,'fa050000-0000-4000-8000-000000000002',wallet_id,true,false,true from public.wallets where tenant_id=t;
 insert into public.financial_types(tenant_id,name,origin,account,allocations) values(t,'Acceptance expense','custom','operating_expense','{"lpg":100}') returning type_id into ft;
 insert into visibility_fixture values('type',ft);
 perform public.record_financial_entry(jsonb_build_object('type_id',ft,'expected_revision',1,'wallet_id',(select value from visibility_fixture where key='cash'),'amount',9,'date',current_date,'description','Owner private entry'),gen_random_uuid());
 insert into app_private.user_permission_sets values(t,'fa050000-0000-4000-8000-000000000002',array['finance:view','finance:manage','finance:entries','finance:entries:view','finance:returns','wallets:use','wallets:ledger','wallets:transfer','reports:view','finance:activity']);
end$$;

-- Only actual customer returns compact. Purchase layers never merge.
do $$declare t uuid:=app_private.current_tenant_id();b uuid;i uuid;r jsonb;n integer;q integer;cost numeric;cid uuid;before_layers bigint;begin
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Consecutive cost grouping') returning brand_id into b;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,b,12,'22mm') returning item_id into i;
 perform public.adjust_inventory(jsonb_build_object('item_id',i,'kind','capital','filled_quantity',100,'empty_quantity',0,'filled_unit_cost',3000,'filled_shell_unit_cost',1900,'reason','Grouping fixture stock'),gen_random_uuid());
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price) values(t,i,'retail','refill',1500),(t,i,'retail','package',4000);
 for n in 1..30 loop
  q:=case n when 1 then 1 when 2 then 13 when 3 then 2 when 30 then 4 else 1 end;
  cost:=case when n<=3 or n=30 then 1900 when n=4 then 2000 else 1900+n end;
  perform public.set_product_buying_price(jsonb_build_object('item_id',i,'price_type','bottle','is_manual',true,'price',cost,'reason','Grouping fixture reference','expected',(select history_id from public.product_buying_price_history where tenant_id=t and item_id=i and price_type='bottle' order by effective_at desc,entry_no desc limit 1)),gen_random_uuid());
  r:=public.create_pos_sale('01790000056','FIFO grouping customer',null,null,'retail',0,0,'Grouping acceptance',jsonb_build_array(jsonb_build_object('item_id',i,'type','refill','quantity',q,'unit_price',1500),jsonb_build_object('item_id',i,'type','empty_return','quantity',q,'unit_price',0)),p_customer_id=>cid,p_request_id=>gen_random_uuid(),p_payments=>'[]');
  select customer_id into cid from public.sales where tenant_id=t and sale_id=(r->>'sale_id')::uuid;
 end loop;
 select count(*) into before_layers from app_private.fifo_layers where tenant_id=t and item_id=i;
 r:=public.get_fifo_stock(i,'retail','empty',0);
 perform pg_temp.assert((r->>'total')::integer=28,'Only consecutive equal-cost customer returns combine before pagination');
 perform pg_temp.assert((r->'layers'->0->>'remaining')::integer=16 and (r->'layers'->0->>'bottle_value')::numeric=30400 and (r->'layers'->0->>'source_count')::integer=3,'Screenshot returns combine with exact quantity, cost and source count');
 perform pg_temp.assert(jsonb_array_length(r->'layers')=25,'Group pagination happens after compaction');
 r:=public.get_fifo_stock(i,'retail','empty',25);
 perform pg_temp.assert(jsonb_array_length(r->'layers')=3 and (r->'layers'->0->>'group_id')::integer=26,'Second page retains group sequence');
 perform pg_temp.assert((r->'layers'->2->>'remaining')::integer=4,'A recurring nonconsecutive cost stays separate');
 perform pg_temp.assert((select count(*)=before_layers from app_private.fifo_layers where tenant_id=t and item_id=i),'Report preserves every acquisition record');
 perform pg_temp.assert((r->'summary'->>'carrying_value')::numeric=(select sum(remaining_value+remaining_internal_value) from app_private.fifo_layers where tenant_id=t and item_id=i and component='empty'),'Grouped costs reconcile to original available empty stock');
end$$;

-- Independent delegated price capabilities must also hold for direct RPC requests.
create temp table permission_restore as select * from app_private.user_permission_sets where user_id='fa050000-0000-4000-8000-000000000002';
update app_private.user_permission_sets set permissions=array['inventory:view','inventory:manage','inventory:prices'] where user_id='fa050000-0000-4000-8000-000000000002';
select pg_temp.fixture_identity('fa050000-0000-4000-8000-000000000002');
set local role authenticated;
do $$declare i uuid:=(select value from visibility_fixture where key='item');expected jsonb;begin
 select jsonb_object_agg(x->>'price_type',x->'effective_from') into expected from jsonb_array_elements(public.get_product_inventory(i)->'prices')x where x->>'customer_tier'='retail';
 begin perform public.save_product_prices(i,'retail','{"refill":{"price":1250,"mrp":1},"package":{"price":3000,"mrp":1}}',expected);raise exception 'Selling capability changed MRP';exception when insufficient_privilege then null;end;
 perform public.save_product_prices(i,'retail','{"refill":{"price":1250,"mrp":null},"package":{"price":3000,"mrp":null}}',expected);
 begin perform public.set_product_buying_price(jsonb_build_object('item_id',i,'price_type','gas','is_manual',true,'price',1,'reason','Denied separate buying override'),gen_random_uuid());raise exception 'Selling capability changed buying reference';exception when insufficient_privilege then null;end;
end$$;
reset role;
update app_private.user_permission_sets set permissions=array['inventory:view','inventory:manage','inventory:mrp'] where user_id='fa050000-0000-4000-8000-000000000002';
set local role authenticated;
do $$declare i uuid:=(select value from visibility_fixture where key='item');expected jsonb;begin
 select jsonb_object_agg(x->>'price_type',x->'effective_from') into expected from jsonb_array_elements(public.get_product_inventory(i)->'prices')x where x->>'customer_tier'='retail';
 begin perform public.save_product_prices(i,'retail','{"refill":{"price":1251,"mrp":null},"package":{"price":3000,"mrp":null}}',expected);raise exception 'MRP capability changed selling price';exception when insufficient_privilege then null;end;
 perform public.save_product_prices(i,'retail','{"refill":{"price":1250,"mrp":1400},"package":{"price":3000,"mrp":3300}}',expected);
end$$;
reset role;
update app_private.user_permission_sets s set permissions=r.permissions from permission_restore r where s.user_id=r.user_id and s.tenant_id=r.tenant_id;
select pg_temp.fixture_identity('fa050000-0000-4000-8000-000000000002');
set local role authenticated;
select pg_temp.assert(not ('reports:view'=any(public.get_my_permissions())) and not ('finance:activity'=any(public.get_my_permissions())),'Hidden balances suppress aggregate Cash permissions');
select pg_temp.assert(not exists(select 1 from jsonb_array_elements(public.get_finance_wallets())x where x->'balance'<>'null'::jsonb or x->'opening_balance'<>'null'::jsonb),'Wallet response never exposes hidden balances');
do $$begin
 begin perform balance from public.wallets;raise exception 'Raw wallet leak';exception when insufficient_privilege then null;end;
 begin perform balance_after from public.wallet_transactions;raise exception 'Raw history leak';exception when insufficient_privilege then null;end;
 begin perform public.get_finance_analysis(jsonb_build_object('from',current_date,'to',current_date));raise exception 'Aggregate Cash leak';exception when insufficient_privilege then null;end;
end$$;
select public.record_financial_entry(jsonb_build_object('type_id',(select value from visibility_fixture where key='type'),'expected_revision',1,'wallet_id',(select value from visibility_fixture where key='cash'),'amount',11.25,'date',current_date,'description','Use without seeing balance'),gen_random_uuid());
select pg_temp.assert((public.get_financial_entries()->>'total')::integer=1,'Own-entry read permission excludes other staff entries');
select pg_temp.assert(not exists(select 1 from jsonb_array_elements(public.get_wallet_ledger()->'entries')x where x->'balance_after'<>'null'::jsonb),'Ledger amounts remain visible but running balances are redacted');
reset role;
do $$declare t uuid:=(select value from visibility_fixture where key='tenant');begin
 perform pg_temp.assert((select balance=-20.25 from public.wallets where tenant_id=t and type='cash'),'Hidden-wallet entry posts exactly once');
 update app_private.user_wallet_access set can_use=false,can_history=false where tenant_id=t and user_id='fa050000-0000-4000-8000-000000000002' and wallet_id=(select value from visibility_fixture where key='bank');
end$$;
set local role authenticated;
do $$begin
 begin perform public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',(select value from visibility_fixture where key='cash'),'destination_id',(select value from visibility_fixture where key='bank'),'amount',10,'reason','Denied destination'),gen_random_uuid());raise exception 'Unauthorized wallet use';exception when insufficient_privilege then null;end;
end$$;
select pg_temp.assert(not exists(select 1 from jsonb_array_elements(public.get_wallet_ledger()->'entries')x where x->>'wallet_id'=(select value::text from visibility_fixture where key='bank')),'Unauthorized wallet history excluded');
reset role;
select pg_temp.assert((select balance=-20.25 from public.wallets where tenant_id=(select value from visibility_fixture where key='tenant') and type='cash'),'Denied transfer is atomic, no first-leg money disappears');
update app_private.user_permission_sets set permissions=array['pos:sell'] where user_id='fa050000-0000-4000-8000-000000000002';
update app_private.user_wallet_access set can_balance=true where user_id='fa050000-0000-4000-8000-000000000002' and wallet_id=(select value from visibility_fixture where key='cash');
set local role authenticated;
select pg_temp.assert(not ('finance:view'=any(public.get_my_permissions())),'POS-only user does not gain Finance workspace access');
select pg_temp.assert(exists(select 1 from jsonb_array_elements(public.get_finance_wallets())x where x->>'wallet_id'=(select value::text from visibility_fixture where key='cash') and (x->>'balance')::numeric=-20.25),'Individual Balance permission works independently of Finance workspace and global wallet defaults');
select pg_temp.assert(not exists(select 1 from jsonb_array_elements(public.get_finance_wallets())x where x->>'wallet_id'=(select value::text from visibility_fixture where key='bank')),'A wallet with no scopes is completely omitted');
reset role;

set local role authenticated;
do $$begin
 begin perform public.get_fifo_stock((select value from visibility_fixture where key='item'),'retail','all',0);raise exception 'POS-only account read FIFO';exception when insufficient_privilege then null;end;
end$$;
reset role;
