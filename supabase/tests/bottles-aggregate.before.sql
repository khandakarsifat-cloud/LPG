-- Run on the local LPG database through execute_sql/psql. All fixtures roll back.
set row_security=on;
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



do $$declare result jsonb;sid uuid;begin
 result:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,'Historical tracked sale',
 '[{"item_id":"c3333333-3333-4333-8333-333333333333","type":"refill","quantity":5,"unit_price":100},{"item_id":"c3333333-3333-4333-8333-333333333333","type":"empty_return","quantity":5,"unit_price":0}]',
 'c5555555-5555-4555-8555-555555555555','ca000000-0000-4000-8000-000000000001','[]',
 '{"lines":[{"expected_item_id":"c3333333-3333-4333-8333-333333333333","received_item_id":"c3333333-3333-4333-8333-333333333333","quantity":1}],"note":"Four bottles due later"}');
 sid:=(result->>'sale_id')::uuid;
 perform public.collect_sale_bottles(sid,
 '{"lines":[{"expected_item_id":"c3333333-3333-4333-8333-333333333333","received_item_id":"cb000000-0000-4000-8000-000000000001","quantity":1}],"note":"Historical brand exchange fee","fee":20}',
 'ca000000-0000-4000-8000-000000000002');
end $$;
reset role;
create schema aggregate_migration_fixture;
create table aggregate_migration_fixture.preservation as select
 (select md5(jsonb_agg(to_jsonb(s) order by tenant_id,sale_id)::text) from public.sales s) sales,
 (select md5(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text) from public.items i) stock,
 (select md5(jsonb_agg(to_jsonb(m) order by tenant_id,movement_id)::text) from public.inventory_movements m) movements,
 (select md5(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text) from public.wallets w) wallets,
 (select md5(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text) from public.wallet_transactions w) ledger,
 (select md5(jsonb_agg(to_jsonb(r) order by tenant_id,receipt_id)::text) from public.sale_bottle_receipts r) receipts,
 (select md5(jsonb_agg(to_jsonb(l) order by tenant_id,line_id)::text) from public.sale_bottle_receipt_lines l) lines;
commit;
