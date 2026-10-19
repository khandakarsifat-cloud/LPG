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
set local role authenticated;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);
do $$
declare result jsonb; payload jsonb := '[{"item_id":"c3333333-3333-4333-8333-333333333333","type":"package","quantity":1,"unit_price":2300}]';
begin
 result := public.create_pos_sale('01700000000',null,null,null,'wholesale',100,50,null,payload,'c5555555-5555-4555-8555-555555555555');
 if result->>'sale_tier' <> 'wholesale' or (result->>'total_amount')::numeric <> 2250
 or not exists(select 1 from public.sales where sale_id=(result->>'sale_id')::uuid and sale_tier='wholesale') then
   raise exception 'Wholesale classification or sale totals were lost';
 end if;
 if (select tier from public.customers where customer_id='c5555555-5555-4555-8555-555555555555') <> 'retail' then
   raise exception 'Sale tier changed the customer profile';
 end if;
 result := public.create_pos_sale('01700000001',null,null,null,'retail',0,0,null,payload,'c6666666-6666-4666-8666-666666666666');
 if result->>'sale_tier' <> 'retail' then raise exception 'Retail override was not stored'; end if;
 result := public.create_pos_sale('01700000002','New wholesale','Shop',null,'wholesale',0,0,null,payload);
 if result->>'sale_tier' <> 'wholesale' then raise exception 'New customer wholesale sale failed'; end if;
 result := public.create_pos_sale('01700000003',null,null,null,null,0,0,null,payload);
 if result->>'sale_tier' <> 'retail' then raise exception 'Null/legacy tier must default to retail'; end if;
 begin
   perform public.create_pos_sale('01700000004',null,null,null,'invalid',0,0,null,payload);
   raise exception 'Invalid tier accepted';
 exception when raise_exception then
   if sqlerrm <> 'Invalid sale tier' then raise; end if;
 end;
 if (select count(*) from public.sales) <> 4 or exists(select 1 from public.customers where phone='01700000004') then
   raise exception 'Invalid tier created business data';
 end if;
 if (select filled_quantity from public.items limit 1) <> 6 or (select empty_quantity from public.items limit 1) <> 6 then
   raise exception 'Sale stock changes were not applied once';
 end if;
 if has_table_privilege('authenticated','public.sales','UPDATE') then raise exception 'Browser can rewrite sale tier'; end if;
 begin
   update public.sales set sale_tier='retail';
   raise exception 'Browser rewrote a saved sale';
 exception when insufficient_privilege then null;
 end;
end $$;
reset role;
-- A later customer reclassification cannot rewrite the already captured sale tier.
update public.customers set tier='retail' where tenant_id='c1111111-1111-4111-8111-111111111111';
do $$ begin
 if (select count(*) from public.sales where tenant_id='c1111111-1111-4111-8111-111111111111' and sale_tier='wholesale') <> 2 then
   raise exception 'Historical sale classification follows mutable customer tier';
 end if;
 begin
   update public.sales set sale_tier='invalid' where tenant_id='c1111111-1111-4111-8111-111111111111';
   raise exception 'Invalid persisted tier accepted';
 exception when check_violation then null;
 end;
 begin
   update public.sales set sale_tier=null where tenant_id='c1111111-1111-4111-8111-111111111111';
   raise exception 'Null persisted tier accepted';
 exception when not_null_violation then null;
 end;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','d2222222-2222-4222-8222-222222222222',true);
do $$ begin
 if exists(select 1 from public.sales) then raise exception 'Cross-tenant sale tier read allowed'; end if;
end $$;
reset role;
select 'PASS: sale tier snapshots, saved/new customers, both overrides, validation, stock and tenant boundaries' as verification;
rollback;
