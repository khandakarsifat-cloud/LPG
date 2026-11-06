create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',message;end if;end$$;
grant execute on function pg_temp.assert(boolean,text) to authenticated,anon;
create temp table core_security_fixture(key text,value uuid);
grant select on core_security_fixture to authenticated,anon;
insert into auth.users(id,email,is_anonymous) values
 ('fc051000-0000-4000-8000-000000000001','core-owner-a@example.invalid',false),
 ('fc052000-0000-4000-8000-000000000001','core-owner-b@example.invalid',false),
 ('fc053000-0000-4000-8000-000000000001','core-sales-agent@example.invalid',false);
select pg_temp.fixture_identity('fc051000-0000-4000-8000-000000000001');
insert into core_security_fixture select 'tenant_a',(pg_temp.fixture_business('Core security disposable A','Owner A')->>'tenant_id')::uuid;
select pg_temp.fixture_identity('fc052000-0000-4000-8000-000000000001');
insert into core_security_fixture select 'tenant_b',(pg_temp.fixture_business('Core security disposable B','Owner B')->>'tenant_id')::uuid;
do $$declare t uuid;brand uuid;item uuid;plant uuid;result jsonb;begin
 select value into t from core_security_fixture where key='tenant_b';
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Private tenant B brand') returning brand_id into brand;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,12,'22mm') returning item_id into item;
 insert into public.gas_plants(tenant_id,brand_id,plant_name) values(t,brand,'Private tenant B plant') returning plant_id into plant;
 result:=public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'items',jsonb_build_array(jsonb_build_object('item_id',item,'quantity',2,'bottle_quantity',2,'unit_price',800,'bottle_unit_price',1600))));
 insert into core_security_fixture values('purchase_b',(result->>'purchase_id')::uuid),('item_b',item);
 insert into core_security_fixture select 'wallet_b',wallet_id from public.wallets where tenant_id=t and type='cash';
 select value into t from core_security_fixture where key='tenant_a';
 perform pg_temp.fixture_identity('fc051000-0000-4000-8000-000000000001');
 insert into core_security_fixture select 'wallet_a',wallet_id from public.wallets where tenant_id=t and type='cash';
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Owner A own brand') returning brand_id into brand;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,12,'22mm');
 insert into public.user_profiles(user_id,tenant_id,email,full_name) values('fc053000-0000-4000-8000-000000000001',t,'core-sales-agent@example.invalid','Sales agent');
 insert into public.user_roles(tenant_id,user_id,role_id) select t,'fc053000-0000-4000-8000-000000000001',role_id from public.roles where tenant_id=t and name='SALESMAN';
end$$;
select pg_temp.fixture_identity('fc051000-0000-4000-8000-000000000001');
set local role authenticated;
select pg_temp.assert((select count(*)=0 from public.items where tenant_id=(select value from core_security_fixture where key='tenant_b')),'Raw table RLS hides another tenant inventory');
select pg_temp.assert((select count(*)=1 from public.items where tenant_id=(select value from core_security_fixture where key='tenant_a')),'RLS still exposes the owner own inventory');
select pg_temp.assert((select count(*)=0 from public.get_purchases_by_ids(array[(select value from core_security_fixture where key='purchase_b')])),'Protected directory cannot expose another tenant purchase');
select pg_temp.assert((select count(*)=0 from public.get_purchase_activity((select value from core_security_fixture where key='purchase_b'),0,7)),'Purchase history cannot expose another tenant purchase');
do $$begin
 begin
  perform public.set_purchase_rebate((select value from core_security_fixture where key='purchase_b'),'{"amount":1,"revision":1}',gen_random_uuid());
  raise exception 'FAIL: cross-tenant rebate accepted';
 exception when others then if sqlerrm<>'Purchase not found' then raise;end if;end;
 begin
  perform public.receive_purchase((select value from core_security_fixture where key='purchase_b'),1);
  raise exception 'FAIL: cross-tenant receipt accepted';
 exception when others then if sqlerrm<>'Purchase not found' then raise;end if;end;
 begin
  perform public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',(select value from core_security_fixture where key='wallet_a'),'destination_id',(select value from core_security_fixture where key='wallet_b'),'amount',1,'reason','Forbidden cross-tenant destination'),gen_random_uuid());
  raise exception 'FAIL: cross-tenant money transfer accepted';
 exception when others then if sqlerrm<>'Active destination wallet not found' then raise;end if;end;
 begin
  perform public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'commission',1));
  raise exception 'FAIL: obsolete commission purchase contract accepted';
 exception when others then if sqlerrm<>'Unsupported purchase fields' then raise;end if;end;
end$$;
reset role;
select pg_temp.fixture_identity('fc053000-0000-4000-8000-000000000001');
set local role authenticated;
do $$begin
 begin
  perform public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',(select value from core_security_fixture where key='wallet_a'),'destination_id',(select value from core_security_fixture where key='wallet_b'),'amount',1,'reason','Sales role is not treasury administrator'),gen_random_uuid());
  raise exception 'FAIL: sales agent transferred treasury money';
 exception when insufficient_privilege then null;end;
 begin
  perform public.set_product_buying_price(jsonb_build_object('item_id',(select value from core_security_fixture where key='item_b'),'price_type','bottle','price',1,'is_manual',true,'reason','Unauthorized price change'),gen_random_uuid());
  raise exception 'FAIL: sales agent changed acquisition reference';
 exception when insufficient_privilege then null;end;
end$$;
reset role;
select pg_temp.fixture_identity(null);
set local role anon;
do $$begin
 begin
  perform public.get_finance_analysis(jsonb_build_object('from',(now() at time zone 'Asia/Dhaka')::date,'to',(now() at time zone 'Asia/Dhaka')::date));
  raise exception 'FAIL: anonymous caller read financial analysis';
 exception when insufficient_privilege then null;end;
end$$;
reset role;
select pg_temp.assert(not has_function_privilege('anon','public.receive_purchase(uuid,integer,date)','execute'),'New receipt API is not granted anonymously');
select pg_temp.assert(not has_function_privilege('authenticated','app_private.purchase_components(uuid,uuid)','execute'),'Private acquisition helper remains inaccessible to clients');
select pg_temp.assert(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app_private') and p.proname ilike '%commission%'),'Superseded commission RPCs and helpers are removed');
select pg_temp.assert(not exists(select 1 from pg_tables where schemaname='public' and tablename ilike '%commission%'),'Superseded commission tables are removed');
select pg_temp.assert(not exists(select 1 from information_schema.columns where table_schema='public' and table_name='wallets' and column_name='business_balances'),'No wallet sub-balance field remains');
select pg_temp.assert((select count(*)=1 from pg_proc where pronamespace='public'::regnamespace and proname='receive_purchase'),'Receipt has one canonical RPC signature');
select pg_temp.assert(not exists(select 1 from pg_tables where schemaname='public' and not rowsecurity),'Every exposed application table retains RLS');
select pg_temp.assert(to_regclass('public.financial_source_archive') is null and to_regprocedure('public.get_financial_source_archive(uuid,integer,integer)') is null,'Retired archive table and compatibility RPC are removed');
select pg_temp.assert(to_regprocedure('app_private.rebuild_fifo(uuid,uuid)') is null,'Unused single-SKU FIFO rebuild wrapper is removed');

select pg_temp.assert(not has_function_privilege('anon','public.set_purchase_rebate(uuid,jsonb,uuid)','execute'),'Anonymous rebate writes are denied');
