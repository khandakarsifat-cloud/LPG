-- Run on the local LPG database through execute_sql/psql. All fixtures roll back.
begin;

insert into public.tenants(tenant_id, business_name) values
  ('c1111111-1111-4111-8111-111111111111', 'Printer integration test A'),
  ('d1111111-1111-4111-8111-111111111111', 'Printer integration test B');
insert into auth.users(id, email, is_anonymous) values
  ('c2222222-2222-4222-8222-222222222222', 'tier-a@example.invalid', false),
  ('d2222222-2222-4222-8222-222222222222', 'tier-b@example.invalid', false);
insert into public.user_profiles(user_id, tenant_id, email) values
  ('c2222222-2222-4222-8222-222222222222', 'c1111111-1111-4111-8111-111111111111', 'tier-a@example.invalid'),
  ('d2222222-2222-4222-8222-222222222222', 'd1111111-1111-4111-8111-111111111111', 'tier-b@example.invalid');
insert into public.roles(tenant_id, role_id, name) values
  ('c1111111-1111-4111-8111-111111111111', 'c4444444-4444-4444-8444-444444444444', 'OWNER'),
  ('d1111111-1111-4111-8111-111111111111', 'd4444444-4444-4444-8444-444444444444', 'OWNER');
insert into public.role_permissions(tenant_id, role_id, permission_id)
select r.tenant_id, r.role_id, p.permission_id from public.roles r cross join public.permissions p
where r.tenant_id in ('c1111111-1111-4111-8111-111111111111', 'd1111111-1111-4111-8111-111111111111');
insert into public.user_roles(tenant_id, user_id, role_id) values
  ('c1111111-1111-4111-8111-111111111111', 'c2222222-2222-4222-8222-222222222222', 'c4444444-4444-4444-8444-444444444444'),
  ('d1111111-1111-4111-8111-111111111111', 'd2222222-2222-4222-8222-222222222222', 'd4444444-4444-4444-8444-444444444444');
insert into public.items(tenant_id, item_id, brand, size_kg, filled_quantity, empty_quantity)
  values ('c1111111-1111-4111-8111-111111111111', 'c3333333-3333-4333-8333-333333333333', 'Print test item', 12, 10, 10);

insert into public.customers(tenant_id,customer_id,name,phone,tier) values
 ('c1111111-1111-4111-8111-111111111111','c5555555-5555-4555-8555-555555555555','Saved retail','01700000000','retail'),
 ('c1111111-1111-4111-8111-111111111111','c6666666-6666-4666-8666-666666666666','Saved wholesale','01700000001','wholesale'),
 ('d1111111-1111-4111-8111-111111111111','c5555555-5555-4555-8555-555555555555','Other tenant','01700000000','retail');
insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from) values ('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333333','retail','package',2300,now()-interval '1 day');
set local role authenticated;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);

reset role;
insert into public.items(tenant_id,item_id,brand,size_kg,mouth_size,filled_quantity,empty_quantity) values
 ('c1111111-1111-4111-8111-111111111111','cb000000-0000-4000-8000-000000000001','Other brand',12,'22mm',20,10),
 ('c1111111-1111-4111-8111-111111111111','cb000000-0000-4000-8000-000000000002','Different size',5,'20mm',20,10);
update public.items set mouth_size='22mm',filled_quantity=100,empty_quantity=10 where item_id='c3333333-3333-4333-8333-333333333333';
insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from) values
 ('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333333','retail','refill',100,now()-interval '1 day');
set local role authenticated;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);



do $$declare sid uuid; body jsonb; result jsonb; rid uuid:=gen_random_uuid(); cash uuid; a uuid:='c3333333-3333-4333-8333-333333333333';begin
 select wallet_id into cash from public.wallets where type='cash';
 result:=public.create_pos_sale('01700000000',null,null,null,'retail',0,20,null,
 jsonb_build_array(jsonb_build_object('item_id',a,'type','refill','quantity',5,'unit_price',100),jsonb_build_object('item_id',a,'type','empty_return','quantity',5,'unit_price',0)),
 'c5555555-5555-4555-8555-555555555555',gen_random_uuid(),'[]','{"lines":[]}');sid:=(result->>'sale_id')::uuid;
 body:=jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',2)),'expense',100,'expense_wallet_id',cash);
 result:=public.collect_sale_bottles(sid,body,rid);
 perform set_config('lpg.legacy_sale',sid::text,false);perform set_config('lpg.legacy_request',rid::text,false);
end $$;
reset role;
create schema settlement_migration_fixture;
create table settlement_migration_fixture.state as select * from public.finance_requests where request_id=current_setting('lpg.legacy_request')::uuid;
-- Snapshot every public business row, including original invoice, payments, expense and stock.
create function settlement_migration_fixture.snapshot() returns jsonb language plpgsql as $$declare r record; result jsonb:='{}'; hash text;begin
 for r in select tablename from pg_tables where schemaname='public' order by tablename loop
 execute format('select md5(coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text)::text,%L)) from public.%I x','',r.tablename) into hash;
 result:=result||jsonb_build_object(r.tablename,hash);end loop;return result;end $$;
create table settlement_migration_fixture.preservation as select settlement_migration_fixture.snapshot() before;
grant usage on schema settlement_migration_fixture to authenticated;grant select on settlement_migration_fixture.state to authenticated;
commit;
