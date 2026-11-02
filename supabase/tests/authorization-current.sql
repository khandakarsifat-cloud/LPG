-- Current canonical contracts. Historical authorization.sql remains at its
-- original migration replay boundary; removed unvalued stock RPCs stay removed.
begin;
create function pg_temp.assert_current(ok boolean,note text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',note;end if;end $$;
create function pg_temp.expect_current_error(statement text,pattern text) returns void language plpgsql as $$begin
 begin execute statement;exception when others then if sqlerrm~*pattern then return;end if;raise;end;
 raise exception 'FAIL: unauthorized/invalid statement succeeded';end $$;
grant execute on function pg_temp.assert_current(boolean,text),pg_temp.expect_current_error(text,text) to authenticated,anon;
insert into auth.users(id,email,is_anonymous) values('fc010000-0000-4000-8000-000000000001','current-owner-a@example.invalid',false),('fc020000-0000-4000-8000-000000000001','current-owner-b@example.invalid',false),('fc030000-0000-4000-8000-000000000001','current-manager@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','fc010000-0000-4000-8000-000000000001',true);
select public.setup_business('Current authorization A','Owner A');
select set_config('request.jwt.claim.sub','fc020000-0000-4000-8000-000000000001',true);
select public.setup_business('Current authorization B','Owner B');
reset role;
create temp table current_auth_fixture(t uuid,item uuid,brand uuid,other_t uuid);
do $$declare t uuid;other_t uuid;b uuid;i uuid;begin
 select tenant_id into t from public.user_profiles where user_id='fc010000-0000-4000-8000-000000000001';select tenant_id into other_t from public.user_profiles where user_id='fc020000-0000-4000-8000-000000000001';
 b:=pg_temp.fixture_brand(t,'Current isolation brand');insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,b,12,'22mm') returning item_id into i;
 insert into current_auth_fixture values(t,i,b,other_t);
 insert into public.user_profiles(user_id,tenant_id,full_name,email) values('fc030000-0000-4000-8000-000000000001',t,'Fixture manager','current-manager@example.invalid');
 insert into public.user_roles(tenant_id,user_id,role_id) select t,'fc030000-0000-4000-8000-000000000001',role_id from public.roles where tenant_id=t and name='MANAGER';
end $$;
grant select on current_auth_fixture to authenticated,anon;
set local role authenticated;
select set_config('request.jwt.claim.sub','fc010000-0000-4000-8000-000000000001',true);
do $$declare i uuid:=(select item from current_auth_fixture);d date:=date_trunc('month',now() at time zone 'Asia/Dhaka')::date;p jsonb;key uuid:=gen_random_uuid();begin
 p:=jsonb_build_object('item_id',i,'month',d,'package_rate',45,'refill_rate',45,'expected_revision',0,'reason','Owner evidence');
 perform public.set_monthly_commission(p,key);perform public.set_monthly_commission(p,key);
 perform pg_temp.assert_current((public.get_monthly_commissions(i,d)->>'total')::integer=1,'Matching retries create one rate revision');
 perform pg_temp.expect_current_error(format('select public.set_monthly_commission(%L::jsonb,%L::uuid)',(p||'{"package_rate":55,"refill_rate":55}'),key),'different details');
 perform pg_temp.expect_current_error(format('select public.set_monthly_commission(%L::jsonb,%L::uuid)',p,gen_random_uuid()),'changed');
 perform pg_temp.expect_current_error(format('select public.set_monthly_commission(%L::jsonb,%L::uuid)',p||'{"package_rate":-1,"refill_rate":-1}',gen_random_uuid()),'valid month');
end $$;
select pg_temp.expect_current_error('select * from public.monthly_commission_rates','permission denied');
select pg_temp.expect_current_error('select * from app_private.fifo_layers','permission denied');
select pg_temp.expect_current_error('select app_private.rebuild_fifo(gen_random_uuid(),gen_random_uuid())','permission denied');
select set_config('request.jwt.claim.sub','fc030000-0000-4000-8000-000000000001',true);
select pg_temp.expect_current_error(format('select public.set_monthly_commission(%L::jsonb,gen_random_uuid())',jsonb_build_object('item_id',item,'month',date_trunc('month',now() at time zone 'Asia/Dhaka')::date,'package_rate',60,'refill_rate',60,'expected_revision',1,'reason','Manager denied')),'Only the owner') from current_auth_fixture;
select set_config('request.jwt.claim.sub','fc020000-0000-4000-8000-000000000001',true);
select pg_temp.expect_current_error(format('select public.get_monthly_commissions(%L::uuid,%L::date)',item,date_trunc('month',now() at time zone 'Asia/Dhaka')::date),'Eligible LPG product not found') from current_auth_fixture;
select pg_temp.assert_current((select count(*)=0 from public.items where item_id=(select item from current_auth_fixture)),'Other business cannot read the product');
select pg_temp.expect_current_error(format('select public.get_finance_analysis(%L::jsonb)',jsonb_build_object('business_id',t,'from','2026-01-01','to','2026-10-31')),'permission|access|authoriz|business') from current_auth_fixture;
set local role anon;
select pg_temp.expect_current_error('select public.get_monthly_commissions(gen_random_uuid(),current_date)','permission denied');
select pg_temp.expect_current_error('select public.correct_commission_deduction(''{}'',gen_random_uuid())','permission denied');
select pg_temp.expect_current_error('select public.get_customer_directory()','permission denied');
reset role;
select pg_temp.assert_current(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('get_monthly_commissions','set_monthly_commission','correct_commission_deduction') and (has_function_privilege('anon',p.oid,'execute') or p.proconfig is null)),'New RPCs have explicit grants and fixed search paths');
select 'PASS: current owner/manager/anonymous and cross-tenant permissions, private-layer isolation, stale edits, validation and matching/changed retries';
rollback;
