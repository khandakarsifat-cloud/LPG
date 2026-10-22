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
insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description)
 select w.tenant_id,w.wallet_id,case when n%2=0 then 1 else -1 end,'balance_adjustment','Load fixture '||n
 from public.wallets w cross join generate_series(1,20000) n where w.tenant_id='c1111111-1111-4111-8111-111111111111' and w.type='cash';
analyze public.wallet_transactions;
set local role authenticated;
create temporary table ledger_timing(started timestamptz);
insert into ledger_timing values(clock_timestamp());
do $$ declare r jsonb; begin
 r:=public.get_wallet_ledger('{}',10000,25);
 if (r->>'total')::integer<>20000 or jsonb_array_length(r->'entries')<>25 or (r->>'received')::numeric<>10000 or (r->>'paid_out')::numeric<>10000 then raise exception 'Large ledger pagination or aggregate mismatch'; end if;
 r:=public.get_wallet_ledger('{"search":"Load 19999","min":"1","max":"1","direction":"out"}',0,25);
 if (r->>'total')::integer<>1 then raise exception 'Large ledger AND search mismatch'; end if;
 if (public.get_wallet_ledger('{"from":"2000-01-01","to":"2000-01-02"}')->>'total')::integer<>0 then raise exception 'Large ledger date filter mismatch'; end if;
end $$;
select 'PASS: 20,000 ledger entries; deep page, exact counts/sums, AND search and date filters; three RPCs in '||round(extract(epoch from clock_timestamp()-started)*1000)||' ms' from ledger_timing;
rollback;
